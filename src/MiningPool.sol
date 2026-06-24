// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {CurrencyToken} from "./CurrencyToken.sol";
import {PlayerNFT} from "./PlayerNFT.sol";
import {CurrencyNFT} from "./CurrencyNFT.sol";

/// @title MiningPool
/// @notice Central contract for collaborative vanity address mining.
///
/// WHAT THIS CONTRACT DOES:
///   Players submit "shares" — proof-of-work hashes meeting an expected-work target.
///   Each share proves computational effort. The contract tracks each player's
///   cumulative contribution over time using checkpoints (day → cumulative score).
///
///   When a player later discovers a vanity address (a currency), the token
///   distribution is proportional to each player's score at the day before discovery.
///
/// HOW SHARES WORK:
///   The share hash IS the CREATE2 address computation. Every hash attempt
///   simultaneously searches for:
///     1. Low hash value → share work (proof of work)
///     2. Vanity patterns → potential currency discovery (e.g. 0xBadFace...)
///
///   The CREATE2 formula:
///     address = keccak256(0xff ‖ factory ‖ salt ‖ keccak256(initCode))[12:]
///
///   Where:
///     - factory = this contract's address
///     - salt = free search variable (bytes32, iterated rapidly off-chain)
///     - initCode = token bytecode + abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
///     - counter = share submission index (strictly increasing, committed in initCode)
///     - dayHash = on-chain daily randomness (prevents pre-computing shares for future days)
///
/// PRE-COMMITTED WORK (anti-Sybil):
///   Each player declares a target work BEFORE computing. This target is
///   baked into the hash (via constructor params in initCode). You can't retroactively
///   lower your claim — preventing cherry-picking of lucky results.
///
///   Every share earns the pool average as a participation credit; a "valid" share
///   (actual work >= target) earns its target work on top. The combined credit is
///   capped at 1% of the pool total.
///   - If actual work >= target → "valid" share, credited at average + target (capped at 1% of pool)
///   - If actual work < target → "invalid" share, credited at pool average (capped at 1% of pool)
///   - Pool total ALWAYS gets the full actual work (uncapped)
///
/// DAILY SNAPSHOTS:
///   The first share submission on each new day triggers a snapshot of the previous
///   day's pool-wide totals. Currency contracts read these snapshots to calculate
///   proportional distributions.
///
/// DAY HASHES:
///   Each day has a hash derived from on-chain randomness. Players include the day
///   number in their initCode, anchoring shares to a time window. You cannot generate
///   shares for a future day (the dayHash hasn't been published yet).
contract MiningPool {
    using Checkpoints for Checkpoints.Trace256;

    // =========================================================================
    //                              CONSTANTS
    // =========================================================================

    /// @notice Minimum expected work for a share to be accepted.
    ///         Prevents spam submissions. 65,536 work = 1 in 65,536 hashes on average.
    ///         Even a phone CPU can find this in under a second.
    uint256 public constant MIN_SHARE_WORK = 1 << 16;

    /// @notice Maximum credit any single share can receive, as a percentage of
    ///         the pool's total integrated work. Prevents a single lucky
    ///         mega-share from dominating all future distributions.
    ///         100 = 1% (we divide by this, so 100 means 1/100 = 1%)
    uint256 public constant MAX_SHARE_CREDIT_DIVISOR = 100;

    /// @notice Synthetic baseline used to bootstrap early pool economics.
    ///         The pool starts with enough work for a minimum valid share
    ///         to receive full credit under the 1% cap.
    uint256 public constant BOOTSTRAP_SHARE_COUNT = 10;
    uint256 public constant BOOTSTRAP_AVERAGE_WORK = MIN_SHARE_WORK * MAX_SHARE_CREDIT_DIVISOR / BOOTSTRAP_SHARE_COUNT;
    uint256 public constant BOOTSTRAP_INTEGRATED_WORK = BOOTSTRAP_SHARE_COUNT * BOOTSTRAP_AVERAGE_WORK;

    // =========================================================================
    //                              DATA TYPES
    // =========================================================================

    /// @notice Snapshot of pool-wide state at end of a day.
    ///         Frozen when the first submission of the NEXT day arrives.
    struct DaySnapshot {
        uint256 totalShareCount;
        uint256 totalIntegratedWork;
    }

    // =========================================================================
    //                              STATE
    // =========================================================================

    /// @notice Per-player cumulative score checkpoints.
    ///         Key = day number, Value = cumulative score up to and including that day.
    ///         Uses OpenZeppelin's Checkpoints for efficient binary search:
    ///         upperLookup(day) returns the score at the most recent day <= given day.
    mapping(uint256 playerId => Checkpoints.Trace256) internal _playerScores;

    /// @notice Pool-wide cumulative score checkpoints (same structure as player scores).
    ///         Allows currency contracts to look up total pool score at any historical day.
    Checkpoints.Trace256 internal _poolScores;

    /// @notice Frozen daily snapshots. Indexed by day number.
    ///         Set when the first submission of day N+1 arrives, freezing day N's state.
    mapping(uint256 day => DaySnapshot) public daySnapshots;

    /// @notice Day hash for each day. Published once per day.
    ///         Used to anchor shares to a time window and prove non-pre-computation.
    mapping(uint256 day => bytes32) public dayHashes;

    /// @notice The last share counter submitted by each player on each day.
    ///         Shares must be submitted with strictly increasing counters (gaps OK).
    ///         The default value 0 means "no share submitted yet", so the first
    ///         share of a (player, day) must use counter >= 1. Counter 0 is reserved.
    mapping(uint256 playerId => mapping(uint256 day => uint256)) public lastShareCounter;

    /// @notice Running total of all integrated work (uncapped).
    uint256 public totalIntegratedWork;

    /// @notice Running total of all shares submitted.
    uint256 public totalShareCount;

    /// @notice The current day number (incremented on first submission of each new day).
    uint256 public currentDay;

    /// @notice The block.timestamp when day 0 started (contract deployment time).
    ///         Days are calculated as (block.timestamp - dayZeroTimestamp) / 1 days.
    uint256 public immutable dayZeroTimestamp;

    /// @notice The PlayerNFT contract. Deployed by this contract's constructor.
    ///         Mints automatically on a player's first share submission.
    PlayerNFT public immutable playerNFT;

    /// @notice The CurrencyNFT contract. Deployed by this contract's constructor.
    ///         Minted when a player registers a vanity address discovery.
    CurrencyNFT public immutable currencyNFT;

    // =========================================================================
    //                              EVENTS
    // =========================================================================

    event ShareSubmitted(
        uint256 indexed playerId,
        uint256 indexed day,
        uint256 counter,
        bytes32 salt,
        uint256 actualWork,
        uint256 targetWork,
        uint256 creditAwarded,
        bool valid
    );

    event DayAdvanced(uint256 indexed newDay, bytes32 dayHash);

    event CurrencyRegistered(
        uint256 indexed playerId, address indexed vanityAddress, uint256 dayNumber, uint256 counter
    );

    event CurrencyDeployed(
        address indexed vanityAddress, address indexed tokenContract, uint256 totalSupply, uint256 vanityWork
    );

    // =========================================================================
    //                              ERRORS
    // =========================================================================

    error WrongChain(uint256 expected, uint256 actual);
    error CounterNotIncreasing();
    error BelowMinWork();
    error InvalidDayNumber();
    error CurrencyAlreadyRegistered();
    error CurrencyAlreadyDeployed();
    error NotCurrencyOwner();
    error CurrencyNotRegistered();
    error DistributionSnapshotNotFrozen(uint256 snapshotDay, uint256 currentDay);
    error ZeroTotalSupply();
    error ZeroPlayer();
    error DeployedAddressMismatch(address expected, address deployed);

    // =========================================================================
    //                          CONSTRUCTOR
    // =========================================================================

    /// @notice Deploy the MiningPool. Verifies chain ID, starts day 0,
    ///         and deploys the PlayerNFT and CurrencyNFT contracts.
    ///         The expectedChainId parameter prevents accidental deployment
    ///         to the wrong chain. After deployment, the contract address
    ///         itself provides chain binding (it's part of the CREATE2 hash).
    /// @param expectedChainId The chain ID this pool is intended for (e.g. 8453 for Base)
    constructor(uint256 expectedChainId) {
        if (block.chainid != expectedChainId) revert WrongChain(expectedChainId, block.chainid);
        dayZeroTimestamp = block.timestamp;

        // Bootstrap the pool with a synthetic baseline so early shares use the
        // same capped credit path as mature pool activity. The synthetic score
        // is intentionally unowned, so very early distributions leave more dust.
        totalShareCount = BOOTSTRAP_SHARE_COUNT;
        totalIntegratedWork = BOOTSTRAP_INTEGRATED_WORK;
        _poolScores.push(0, BOOTSTRAP_INTEGRATED_WORK);

        // Deploy NFT contracts — they store address(this) as their authorized minter
        playerNFT = new PlayerNFT();
        currencyNFT = new CurrencyNFT();

        // Publish day 0's hash immediately
        bytes32 day0Hash = keccak256(
            abi.encodePacked(
                address(this),
                block.prevrandao,
                uint256(0) // day number
            )
        );
        dayHashes[0] = day0Hash;

        emit DayAdvanced(0, day0Hash);
    }

    // =========================================================================
    //                          CORE FUNCTIONS
    // =========================================================================

    /// @notice Submit a share (proof of work).
    ///
    ///         Anyone can call this on behalf of a player — the player address is
    ///         an explicit parameter, not derived from msg.sender. The CREATE2 hash
    ///         binds the share to the player cryptographically, so submitting with
    ///         a wrong player address just produces an invalid hash. Credits accrue
    ///         to the player's checkpoint and the PlayerNFT owner benefits.
    ///
    /// HOW TO USE (off-chain):
    ///   1. Pick a targetWork — how many hashes you expect to try on average
    ///   2. Pick a dayNumber — use the current day (getCurrentDay())
    ///   3. Pick a counter — must be > your last submitted counter for this day
    ///      (start at 1 for your first share of the day; counter 0 is reserved as "unused")
    ///   4. Get the initCodeHash from getInitCodeHash(yourAddress, dayNumber, targetWork, counter, dayHash)
    ///   5. Search over salt values:
    ///      For each salt, compute:
    ///        hash = keccak256(0xff ‖ poolAddress ‖ salt ‖ initCodeHash)
    ///      Convert the hash to work with hashToWork().
    ///      If actualWork >= targetWork, submit that (counter, salt) pair.
    ///   6. The salt is freely chosen — no ordering constraint.
    ///      The counter must be strictly increasing (gaps OK).
    ///
    /// @param player The player whose address is committed in the CREATE2 hash
    /// @param targetWork The expected-work target the player is betting on
    /// @param dayNumber The day this share references (must be current day or earlier with valid hash)
    /// @param counter Share submission index (must be > last submitted counter for this player+day;
    ///        the first share of a day must use counter >= 1)
    /// @param salt The CREATE2 salt — the free search variable found off-chain
    function submitShare(address player, uint256 targetWork, uint256 dayNumber, uint256 counter, bytes32 salt)
        external
    {
        // --- Validate player ---
        // playerId 0 (the zero address) is not a usable identity — it would fail in
        // the downstream PlayerNFT mint anyway, but revert here with a clear error.
        if (player == address(0)) revert ZeroPlayer();

        // --- Advance day if needed ---
        uint256 today = getCurrentDay();
        if (today > currentDay) {
            _advanceDay(today);
        }

        // --- Validate day number ---
        // Must reference a day whose hash exists (can't be in the future)
        if (dayHashes[dayNumber] == bytes32(0)) revert InvalidDayNumber();

        // --- Player identity ---
        // PlayerId = the player's address cast to uint256.
        // This is also the PlayerNFT tokenId.
        uint256 playerId = uint256(uint160(player));

        // --- Counter ordering ---
        // Must be strictly greater than the last submitted counter for this player+day.
        // The default lastShareCounter is 0 ("nothing submitted yet"), so the first
        // share of a day must use counter >= 1. Players simply start counting at 1.
        if (counter <= lastShareCounter[playerId][dayNumber]) {
            revert CounterNotIncreasing();
        }

        // --- Compute the CREATE2 hash on-chain ---
        // initCodeHash includes the counter (committed per submission) and dayHash
        // (on-chain randomness preventing pre-computation for future days).
        // salt is the free search variable the player iterated over.
        bytes32 dayHash = dayHashes[dayNumber];
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CurrencyToken).creationCode, abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
            )
        );

        bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));

        // Convert the hash to expected work. Lower hashes have higher work.
        uint256 actualWork = hashToWork(create2Hash);

        // Must meet minimum work to prevent spam
        if (actualWork < MIN_SHARE_WORK) revert BelowMinWork();

        // --- Calculate credit ---
        // Participation credit: every accepted share earns the current pool average,
        // rewarding the effort/gas spent even when the pre-committed target was missed.
        // Performance bonus: a valid share (actual work met its target) additionally
        // earns that target work. The combined credit is capped ONCE at 1% of the pool
        // total so no single share can dominate future distributions — the pool's full
        // actual work is still recorded uncapped below.
        uint256 maxCredit = totalIntegratedWork / MAX_SHARE_CREDIT_DIVISOR;
        uint256 credit = totalIntegratedWork / totalShareCount; // pool average (participation)
        bool valid = actualWork >= targetWork && targetWork > 0;
        if (valid) {
            credit += targetWork; // performance bonus for meeting the pre-committed target
        }
        credit = Math.min(credit, maxCredit); // cap combined credit at 1% of pool total

        // --- Update state ---

        // Pool total gets the FULL actual work (uncapped).
        // This means lucky mega-shares boost the pool average for everyone.
        totalIntegratedWork += actualWork;
        totalShareCount += 1;

        // Update player's cumulative score checkpoint.
        // If the player already has a checkpoint for today, it gets updated (not duplicated).
        uint256 previousScore = _playerScores[playerId].upperLookup(today);
        _playerScores[playerId].push(today, previousScore + credit);

        // Update pool-wide cumulative score checkpoint.
        uint256 previousPoolScore = _poolScores.upperLookup(today);
        _poolScores.push(today, previousPoolScore + credit);

        // Update counter tracking
        lastShareCounter[playerId][dayNumber] = counter;

        // Lazy-mint PlayerNFT on first ever submission (idempotent)
        playerNFT.mintIfNeeded(player);

        emit ShareSubmitted(
            playerId,
            today, // recorded under submission day
            counter,
            salt,
            actualWork,
            targetWork,
            credit,
            valid
        );
    }

    /// @notice Publish the current day's hash if it hasn't been published yet.
    ///         STATE-CHANGING: advances the day and freezes the previous day's
    ///         snapshot — exactly like the first submitShare of a new day, but
    ///         without requiring a share. Anyone can call it; idempotent (no-op
    ///         if the current day's hash is already published).
    function getCurrentDayHash() external {
        uint256 today = getCurrentDay();
        if (today > currentDay) {
            _advanceDay(today);
        }
    }

    // =========================================================================
    //                          VIEW FUNCTIONS
    // =========================================================================

    /// @notice Get a player's cumulative score at a given day.
    ///         Used by currency contracts to calculate proportional token distribution.
    ///         Returns the score at the most recent checkpoint at or before the given day.
    /// @param playerId The player's ID (= uint256(uint160(walletAddress)))
    /// @param day The day to look up
    /// @return The cumulative score at that day (0 if no shares submitted by then)
    function getPlayerScoreAt(uint256 playerId, uint256 day) external view returns (uint256) {
        return _playerScores[playerId].upperLookup(day);
    }

    /// @notice Get the pool-wide cumulative score at a given day.
    ///         Used alongside getPlayerScoreAt to calculate proportional shares.
    /// @param day The day to look up
    /// @return The pool-wide cumulative score at that day
    function getPoolScoreAt(uint256 day) external view returns (uint256) {
        return _poolScores.upperLookup(day);
    }

    /// @notice Calculate the current day number based on block.timestamp.
    ///         Day 0 = deployment day. Each day is 24 hours (86400 seconds).
    /// @return The current day number
    function getCurrentDay() public view returns (uint256) {
        return (block.timestamp - dayZeroTimestamp) / 1 days;
    }

    /// @notice Compute the initCodeHash for off-chain mining.
    ///         The initCodeHash is fixed for a given (player, day, target work, counter, dayHash).
    ///         Players compute this once per counter, then iterate over salt values:
    ///           initCodeHash = getInitCodeHash(me, day, targetWork, counter, dayHash)
    ///           for salt in range:
    ///             hash = keccak256(0xff ‖ poolAddress ‖ salt ‖ initCodeHash)
    ///             if hashToWork(hash) >= targetWork: submit(counter, salt)
    ///
    ///         The dayHash parameter is the on-chain daily randomness from dayHashes[dayNumber].
    ///         It prevents players from pre-computing shares for future days, since the
    ///         dayHash is unknowable until getCurrentDayHash() or the first submission triggers its publication.
    ///         Callers must look up the dayHash themselves (this function stays pure).
    ///
    /// @param player The player's wallet address
    /// @param dayNumber The day number being mined
    /// @param targetWork The expected-work target
    /// @param counter The share submission index (committed in initCode)
    /// @param dayHash The on-chain daily randomness for the given day
    /// @return The initCodeHash to use in CREATE2 hash computation
    function getInitCodeHash(address player, uint256 dayNumber, uint256 targetWork, uint256 counter, bytes32 dayHash)
        public
        pure
        returns (bytes32)
    {
        uint256 playerId = uint256(uint160(player));
        return keccak256(
            abi.encodePacked(
                type(CurrencyToken).creationCode, abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
            )
        );
    }

    /// @notice Get the current pool statistics.
    /// @return _totalShares Total number of shares submitted
    /// @return _totalWork Total integrated work (uncapped)
    /// @return _currentDay Current day number
    /// @return _averageWork Current average work per share (0 if no shares)
    function getPoolStats()
        external
        view
        returns (uint256 _totalShares, uint256 _totalWork, uint256 _currentDay, uint256 _averageWork)
    {
        _totalShares = totalShareCount;
        _totalWork = totalIntegratedWork;
        _currentDay = getCurrentDay();
        _averageWork = totalShareCount > 0 ? totalIntegratedWork / totalShareCount : 0;
    }

    /// @notice Convert a CREATE2 hash into expected work.
    /// @dev Mirrors the Bitcoin-style intuition: lower hash value means more
    ///      expected hashes were needed. The all-zero hash saturates to uint256 max.
    /// @param hash The hash to score
    /// @return work Expected work represented by the hash
    function hashToWork(bytes32 hash) public pure returns (uint256 work) {
        uint256 hashValue = uint256(hash);
        if (hashValue == 0) return type(uint256).max;
        return type(uint256).max / hashValue;
    }

    // =========================================================================
    //                    CURRENCY REGISTRATION & DEPLOYMENT
    // =========================================================================

    /// @notice Register a discovered vanity address as a CurrencyNFT.
    ///
    ///         When a player finds a (counter, salt) pair that produces an address
    ///         with an interesting pattern (0xBadFace, 0xDeadBeef, etc.), anyone can
    ///         call this function to register it. The contract recomputes the CREATE2
    ///         address and mints a CurrencyNFT to the player committed in the hash.
    ///
    ///         The caller does not need to be the player — third-party registration
    ///         is safe because the NFT is always minted to the address embedded in
    ///         the CREATE2 computation, not to msg.sender.
    ///
    ///         The NFT grants the right to later deploy a CurrencyToken at that address.
    ///         The dayNumber determines which historical score snapshot is used for
    ///         token distribution. Discoverers can choose any past day with a valid hash
    ///         before mining; the current day is the default behavior. This choice is
    ///         committed into the CREATE2 address, so it cannot be changed ex-post.
    ///
    /// @param player The player whose address is committed in the CREATE2 hash
    /// @param counter The share index (part of initCode, defines the address space)
    /// @param salt The CREATE2 salt (the search variable that produced the vanity address)
    /// @param dayNumber The day to anchor this discovery to (must have a valid hash)
    /// @param targetWork The expected-work target used during search
    /// @return vanityAddress The computed vanity address (also determines the NFT tokenId)
    function registerCurrency(address player, uint256 counter, bytes32 salt, uint256 dayNumber, uint256 targetWork)
        external
        returns (address vanityAddress)
    {
        // Reject the zero address up front (clearer than the downstream PlayerNFT revert).
        if (player == address(0)) revert ZeroPlayer();
        if (dayHashes[dayNumber] == bytes32(0)) revert InvalidDayNumber();

        uint256 playerId = uint256(uint160(player));
        bytes32 dayHash = dayHashes[dayNumber];

        // Compute the CREATE2 address — counter and dayHash are in the initCode, salt is the CREATE2 salt
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(CurrencyToken).creationCode, abi.encode(playerId, dayNumber, targetWork, counter, dayHash)
            )
        );

        bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));

        // The CREATE2 address is the last 20 bytes of the hash
        vanityAddress = address(uint160(uint256(create2Hash)));
        uint256 currencyId = uint256(uint160(vanityAddress));

        // Revert if already registered (ERC721 _mint would revert too, but clearer error)
        if (currencyNFT.isRegistered(vanityAddress)) revert CurrencyAlreadyRegistered();

        // Ensure PlayerNFT exists (lazy-mint if this player never submitted a share)
        playerNFT.mintIfNeeded(player);

        // Mint the CurrencyNFT to whoever currently owns the PlayerNFT —
        // the PlayerNFT is the bearer instrument for the player's identity,
        // so if it was transferred, the new owner receives the discovery.
        address nftOwner = playerNFT.ownerOf(playerId);
        currencyNFT.mint(nftOwner, currencyId, counter, salt, playerId, dayNumber, targetWork, dayHash);

        emit CurrencyRegistered(playerId, vanityAddress, dayNumber, counter);
    }

    /// @notice Deploy a CurrencyToken at a previously registered vanity address.
    ///
    ///         Only the current CurrencyNFT owner can call this. Uses CREATE2 with
    ///         the stored parameters to deploy the token at the exact vanity address.
    ///         The totalSupply is chosen by the deployer at this point — it was
    ///         intentionally excluded from the CREATE2 hash so this choice can be
    ///         deferred to deployment time.
    ///
    ///         Distribution uses the day before discovery as its score snapshot.
    ///         Deployment is only allowed after that snapshot day has passed, which
    ///         guarantees no player can add more shares to the distribution window.
    ///
    ///         The function also auto-boosts totalIntegratedWork by the actual
    ///         expected work of the vanity address. This boost affects only the
    ///         running work total, not share count and not score checkpoints.
    ///         If the discoverer previously submitted the same work as a share, this
    ///         intentionally double-counts as a gift to the commons.
    ///
    /// @param vanityAddress The vanity address to deploy at (must be registered)
    /// @param totalSupply Total ERC-20 supply available for player claims
    /// @return token The deployed CurrencyToken contract
    function deployCurrency(address vanityAddress, uint256 totalSupply) external returns (CurrencyToken token) {
        uint256 currencyId = uint256(uint160(vanityAddress));

        // Verify the currency is registered and not yet deployed
        CurrencyNFT.CurrencyDiscovery memory disc = currencyNFT.getDiscovery(currencyId);
        if (disc.playerId == 0 && disc.dayNumber == 0) revert CurrencyNotRegistered();
        if (disc.deployed) revert CurrencyAlreadyDeployed();

        uint256 snapshotDay = disc.dayNumber > 0 ? disc.dayNumber - 1 : 0;
        uint256 today = getCurrentDay();
        if (today <= snapshotDay) revert DistributionSnapshotNotFrozen(snapshotDay, today);

        // Only the NFT owner can deploy
        if (currencyNFT.ownerOf(currencyId) != msg.sender) revert NotCurrencyOwner();
        if (totalSupply == 0) revert ZeroTotalSupply();

        bytes32 initCodeHash = getInitCodeHash(
            address(uint160(disc.playerId)), disc.dayNumber, disc.targetWork, disc.counter, disc.dayHash
        );
        bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), disc.salt, initCodeHash));
        uint256 vanityWork = hashToWork(create2Hash);

        // Deploy via CREATE2 — Solidity's `new ... {salt: ...}` compiles to CREATE2.
        // The resulting address MUST match vanityAddress because we use the same
        // factory (this), salt, and initCode (CurrencyToken bytecode + constructor args).
        // The counter and dayHash are constructor params (in initCode), salt is the CREATE2 salt.
        token = new CurrencyToken{salt: disc.salt}(
            disc.playerId, disc.dayNumber, disc.targetWork, disc.counter, disc.dayHash
        );

        // Sanity check: deployed address must match the registered vanity address.
        // Use a descriptive revert rather than assert() — assert signals an invariant
        // panic and consumes ALL remaining gas, which is wasteful for what is really a
        // (practically unreachable) input/state mismatch.
        if (address(token) != vanityAddress) revert DeployedAddressMismatch(vanityAddress, address(token));

        token.initializeDistribution(totalSupply);

        // Add the full actual vanity work to the running pool total only.
        // This cannot affect the already-frozen distribution snapshot for this token.
        totalIntegratedWork += vanityWork;

        // Mark as deployed in the NFT
        currencyNFT.markDeployed(currencyId);

        emit CurrencyDeployed(vanityAddress, address(token), totalSupply, vanityWork);
    }

    /// @notice Compute the vanity address for a given set of CREATE2 parameters.
    ///         Useful for off-chain tools to verify an address before registering.
    /// @param player The player's wallet address
    /// @param counter The share index (part of initCode)
    /// @param salt The CREATE2 salt (the search variable)
    /// @param dayNumber The day number
    /// @param targetWork The expected-work target
    /// @param dayHash The on-chain daily randomness for the given day
    /// @return The resulting CREATE2 address
    function computeVanityAddress(
        address player,
        uint256 counter,
        bytes32 salt,
        uint256 dayNumber,
        uint256 targetWork,
        bytes32 dayHash
    ) external view returns (address) {
        bytes32 initCodeHash = getInitCodeHash(player, dayNumber, targetWork, counter, dayHash);
        bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash));
        return address(uint160(uint256(create2Hash)));
    }

    // =========================================================================
    //                          INTERNAL FUNCTIONS
    // =========================================================================

    /// @notice Advance to a new day: snapshot the previous day's state and publish
    ///         the new day's hash. Called automatically on first submission of a new day.
    ///
    ///         O(1) regardless of gap size. If no submissions happened for days 4-7,
    ///         those days simply have no hash (dayHashes[d] == 0) and no shares can
    ///         reference them. Checkpoints bridge the gap automatically — lookups for
    ///         skipped days return the last stored value.
    ///
    /// @param newDay The day number to advance to
    function _advanceDay(uint256 newDay) internal {
        // Snapshot the ending day's pool-wide state.
        // This freezes the running totals so currency minting can read historical state.
        daySnapshots[currentDay] =
            DaySnapshot({totalShareCount: totalShareCount, totalIntegratedWork: totalIntegratedWork});

        // Publish ONLY the new day's hash. Skipped days get no hash — you can't
        // submit shares for them, but that's fine since nobody was mining those days.
        bytes32 newDayHash = keccak256(abi.encodePacked(address(this), block.prevrandao, newDay));
        dayHashes[newDay] = newDayHash;

        currentDay = newDay;

        emit DayAdvanced(newDay, newDayHash);
    }
}
