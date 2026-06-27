// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @notice Minimal interface CurrencyToken uses to read historical scores from MiningPool.
/// @dev Kept in this file instead of importing MiningPool to avoid a circular dependency:
///      MiningPool imports CurrencyToken for the clone implementation, while CurrencyToken
///      only needs this small read-only surface at claim time.
interface IMiningPool {
    function getPlayerScoreAt(uint256 playerId, uint256 day) external view returns (uint256);
    function getPoolScoreAt(uint256 day) external view returns (uint256);
    function playerNFT() external view returns (IPlayerNFT);
}

/// @notice Minimal interface for resolving the current owner of a PlayerNFT tokenId.
/// @dev Currency claims are paid to the current owner of the PlayerNFT, so transferring
///      a PlayerNFT transfers the right to claim distributions for that playerId.
interface IPlayerNFT {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title CurrencyToken
/// @notice ERC-20 meme currency *implementation* behind every vanity CREATE2 address.
///
/// CLONE ARCHITECTURE (why this is an implementation, not a directly-deployed token):
///   Hashing the full ~4.7 KB token creation code on every `submitShare` was the dominant
///   on-chain cost of the mining hot path. To shrink it, each vanity address is now a
///   ~45-byte EIP-1167 minimal proxy (a "clone") that delegatecalls into ONE shared
///   instance of this contract (`MiningPool.currencyImpl`). CREATE2 then hashes only the
///   ~205-byte clone init code, cutting the per-share address computation ~24x.
///
///   Consequences of the clone model (read carefully — these drive the layout below):
///     - NO CONSTRUCTOR RUNS ON A CLONE. The constructor here runs exactly once, on the
///       shared implementation. Clones are born with empty storage and uninitialized.
///     - IMMUTABLES ARE CODE, SO THEY SURVIVE DELEGATECALL. `miningPool` is baked into the
///       implementation's runtime bytecode; a clone delegatecalling in reads the impl's
///       value. Safe to share across all clones (it's the same pool for everyone).
///     - PER-INSTANCE PARAMS LIVE IN THE PROXY, NOT IN IMMUTABLES. The committed params
///       (playerId, dayNumber, targetWork, counter, dayHash) differ per clone, so they
///       CANNOT be constructor immutables (those would bake into the shared impl). They are
///       appended to the clone as immutable args and read at runtime via
///       `Clones.fetchCloneArgs(address(this))` — see {_params}.
///     - NAME/SYMBOL CAN'T BE STORAGE. OZ ERC20 stores name/symbol in storage set by its
///       constructor; on a clone that storage is empty. We therefore override {name} and
///       {symbol} as pure constants (code, not storage), shared by all clones.
///     - ALL OTHER STATE IS CLONE STORAGE. ERC-20 balances/allowances/totalSupply plus the
///       distribution bookkeeping below live at the vanity address's storage, written by
///       {initializeDistribution} and {claim}. Token events are attributed to the vanity
///       address, as desired.
///
/// WHY THESE SPECIFIC COMMITTED PARAMS:
///   The CREATE2 address is determined by:
///     address = keccak256(0xff ‖ factory ‖ salt ‖ keccak256(cloneInitCode))[12:]
///   The committed params are the clone's immutable args, so they are part of the init code
///   and the vanity address binds to them cryptographically (anti-Sybil intact):
///     - playerId:   who discovered this address (also prevents replay across players)
///     - dayNumber:  when it was discovered (anchors to a score-snapshot window)
///     - targetWork: the expected-work bet (prevents retroactive target changes)
///     - counter:    the share submission index (strictly increasing per player per day)
///     - dayHash:    on-chain daily randomness (prevents pre-computing future-day shares)
///   The salt (CREATE2 salt) is the FREE search variable — iterated rapidly off-chain.
///   totalSupply is NOT committed — it's chosen at deployment time by the CurrencyNFT holder,
///   so players don't need to agree on supply during the search phase.
///
/// DEPLOYMENT FLOW:
///   1. Player discovers a vanity address during mining (off-chain search)
///   2. Player registers it as a CurrencyNFT (on-chain)
///   3. CurrencyNFT holder calls deployCurrency() on MiningPool, which clones this impl
///      to the vanity address via CREATE2
///   4. MiningPool initializes the chosen distribution supply
///   5. PlayerNFT owners call claim() to mint their share
///      Supply split: 1% to discoverer, 99% proportional to all players' scores
contract CurrencyToken is ERC20 {
    /// @notice The MiningPool that deployed this implementation (msg.sender during the
    ///         impl's construction). An impl-level immutable: baked into the runtime
    ///         bytecode, so every clone reads the same pool through delegatecall.
    ///         Only the pool can initialize the distribution.
    address public immutable miningPool;

    /// @notice Total token supply reserved for player distribution.
    ///         Set exactly once by MiningPool immediately after the clone is deployed.
    uint256 public distributionSupply;

    /// @notice Historical day used for score lookups.
    ///         For a discovery on day D, claims use scores from day D-1 so players
    ///         cannot rush same-day submissions after seeing a discovery.
    uint256 public snapshotDay;

    /// @notice Pool score at snapshotDay, cached when distribution is initialized.
    ///         Caching freezes the denominator for every later claim and avoids
    ///         repeated external calls to MiningPool.
    uint256 public poolScoreAtSnapshot;

    /// @notice True after MiningPool has set the distribution supply and snapshot.
    bool public initialized;

    /// @notice Tracks whether a playerId has already claimed this currency.
    mapping(uint256 playerId => bool) public claimed;

    error OnlyMiningPool();
    error DistributionAlreadyInitialized();
    error DistributionNotInitialized();
    error DistributionHasNoPoolScore();
    error AlreadyClaimed(uint256 playerId);
    error NothingToClaim(uint256 playerId);
    error CallerNotOwner();

    event DistributionInitialized(uint256 distributionSupply, uint256 snapshotDay, uint256 poolScoreAtSnapshot);

    event Claimed(
        uint256 indexed playerId,
        address indexed recipient,
        uint256 amount,
        uint256 proportionalAmount,
        uint256 discovererBonus
    );

    /// @notice Construct the shared implementation. Runs ONCE (on the impl), never on a clone.
    /// @param _miningPool The MiningPool authorized to initialize distributions on clones.
    ///        Passed explicitly (rather than read as msg.sender) for clarity; MiningPool
    ///        deploys this impl in its own constructor and passes address(this).
    /// @dev The ERC20 name/symbol args are empty placeholders — {name} and {symbol} are
    ///      overridden as pure constants because clone storage is empty (see contract docs).
    constructor(address _miningPool) ERC20("", "") {
        miningPool = _miningPool;
    }

    /// @notice The currency name. Shared by all clones (pure constant, not storage).
    function name() public pure override returns (string memory) {
        return "Vanity Currency";
    }

    /// @notice The currency symbol. Shared by all clones (pure constant, not storage).
    function symbol() public pure override returns (string memory) {
        return "VANITY";
    }

    /// @notice Decode this clone's committed params from its EIP-1167 immutable args.
    /// @dev Reads the args appended to the proxy via `Clones.fetchCloneArgs`. Only
    ///      meaningful when called on a clone; behavior on the bare implementation is
    ///      undefined (the impl is never used as a token).
    function _params()
        internal
        view
        returns (uint256 playerId_, uint256 dayNumber_, uint256 targetWork_, uint256 counter_, bytes32 dayHash_)
    {
        return abi.decode(Clones.fetchCloneArgs(address(this)), (uint256, uint256, uint256, uint256, bytes32));
    }

    /// @notice The player who discovered this vanity address (uint256(uint160(wallet))).
    function playerId() public view returns (uint256 value) {
        (value,,,,) = _params();
    }

    /// @notice The day number this currency was discovered (score-snapshot anchor).
    function dayNumber() public view returns (uint256 value) {
        (, value,,,) = _params();
    }

    /// @notice The expected-work target committed during mining.
    function targetWork() public view returns (uint256 value) {
        (,, value,,) = _params();
    }

    /// @notice The share submission counter committed in the clone init code.
    function counter() public view returns (uint256 value) {
        (,,, value,) = _params();
    }

    /// @notice The on-chain daily randomness anchoring this share to a specific day.
    function dayHash() public view returns (bytes32 value) {
        (,,,, value) = _params();
    }

    /// @notice Initialize token distribution after the clone is deployed.
    ///
    ///         MiningPool calls this exactly once from deployCurrency(), passing the
    ///         total supply chosen by the CurrencyNFT owner. Because a clone has no
    ///         constructor, this explicit call is what populates the clone's storage.
    ///         The snapshot day is derived from the committed discovery day:
    ///
    ///           snapshotDay = dayNumber > 0 ? dayNumber - 1 : 0
    ///
    ///         The pool score denominator is cached immediately so every player uses
    ///         the same frozen value, even if future shares change MiningPool scores.
    ///
    /// @param totalDistributionSupply Total ERC-20 supply available for claims
    function initializeDistribution(uint256 totalDistributionSupply) external {
        if (msg.sender != miningPool) revert OnlyMiningPool();
        if (initialized) revert DistributionAlreadyInitialized();

        (, uint256 day,,,) = _params();
        uint256 snapshot = day > 0 ? day - 1 : 0;
        uint256 poolScore = IMiningPool(miningPool).getPoolScoreAt(snapshot);
        if (poolScore == 0) revert DistributionHasNoPoolScore();

        distributionSupply = totalDistributionSupply;
        snapshotDay = snapshot;
        poolScoreAtSnapshot = poolScore;
        initialized = true;

        emit DistributionInitialized(totalDistributionSupply, snapshot, poolScore);
    }

    /// @notice Claim this currency's allocation for a playerId.
    ///
    ///         Claims are pull-based: the contract does not loop over all players
    ///         because the MiningPool cannot enumerate every participant cheaply.
    ///         The caller must be the current owner of the PlayerNFT for
    ///         `claimPlayerId` — that owner claims their own allocation, and the
    ///         tokens are minted to them. The PlayerNFT is the bearer asset for
    ///         historical score rights.
    ///
    ///         Distribution formula:
    ///
    ///           proportional = distributionSupply * 99 * playerScore
    ///             / (100 * poolScoreAtSnapshot)
    ///
    ///         The discovering playerId also receives:
    ///
    ///           discovererBonus = distributionSupply / 100
    ///
    ///         Integer division leaves any rounding dust unminted.
    ///
    /// @param claimPlayerId PlayerNFT tokenId whose historical score is being claimed
    /// @return amount Total tokens minted to the current PlayerNFT owner
    function claim(uint256 claimPlayerId) external returns (uint256 amount) {
        if (!initialized) revert DistributionNotInitialized();
        if (claimed[claimPlayerId]) revert AlreadyClaimed(claimPlayerId);

        // The caller must own the PlayerNFT whose allocation is being claimed.
        address owner = IMiningPool(miningPool).playerNFT().ownerOf(claimPlayerId);
        if (msg.sender != owner) revert CallerNotOwner();

        uint256 playerScore = IMiningPool(miningPool).getPlayerScoreAt(claimPlayerId, snapshotDay);
        // Redundant invariant check: MiningPool should never report a player
        // score above the pool score at the same snapshot.
        assert(playerScore <= poolScoreAtSnapshot);
        uint256 poolAllocation = Math.mulDiv(distributionSupply, 99, 100);
        uint256 proportionalAmount = Math.mulDiv(poolAllocation, playerScore, poolScoreAtSnapshot);
        (uint256 discovererId,,,,) = _params();
        uint256 discovererBonus = claimPlayerId == discovererId ? distributionSupply / 100 : 0;
        amount = proportionalAmount + discovererBonus;

        if (amount == 0) revert NothingToClaim(claimPlayerId);

        claimed[claimPlayerId] = true;

        _mint(owner, amount);

        emit Claimed(claimPlayerId, owner, amount, proportionalAmount, discovererBonus);
    }
}
