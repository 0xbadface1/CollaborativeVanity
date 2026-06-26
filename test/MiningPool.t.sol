// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {CurrencyToken} from "../src/CurrencyToken.sol";

/// @title MiningPoolHarness
/// @notice Test-only subclass of MiningPool that exposes a setter for the pool's
///         running aggregates.
///
///         WHY THIS EXISTS:
///         The combined-credit cap only "opens up" once totalShareCount > 100 — at
///         that point cap (= totalIntegratedWork / 100) exceeds the pool average
///         (= totalIntegratedWork / totalShareCount), so a valid share's credit
///         (average + target, capped) stops being pinned to the cap the way it is
///         during the 10-share bootstrap. Reaching that regime organically would
///         require submitting ~90 real shares, each costing a ~65K-iteration salt
///         search. Seeding the two aggregates directly lets us exercise the additive
///         path and the final single cap in a fast, deterministic test.
///
///         Only totalShareCount and totalIntegratedWork are seeded — exactly the two
///         values the credit calculation reads. The real submitShare path is still
///         exercised end-to-end on top of the seeded state.
contract MiningPoolHarness is MiningPool {
    constructor(uint256 expectedChainId) MiningPool(expectedChainId) {}

    /// @notice Seed the pool's running aggregates. Test-only — bypasses snapshots
    ///         and score checkpoints, which the credit calculation does not read.
    function setPoolAggregates(uint256 shareCount, uint256 integratedWork) external {
        totalShareCount = shareCount;
        totalIntegratedWork = integratedWork;
    }
}

/// @title MiningPoolTest
/// @notice Foundry test suite for MiningPool.
///
/// HOW FOUNDRY TESTS WORK:
///   - Each function starting with "test" is a separate test case
///   - setUp() runs before EVERY test — each test gets a fresh MiningPool
///   - vm.prank(addr) makes the NEXT call appear as if sent by addr
///   - vm.warp(timestamp) sets block.timestamp to a specific value
///   - vm.expectRevert() expects the next call to revert
///   - vm.expectEmit() sets up event matching for the next call
///   - assertEq(a, b) fails the test if a != b (with a nice diff)
///
/// KEY DESIGN (counter vs salt):
///   - counter: share submission index, part of initCode, strictly increasing per day
///   - salt: free CREATE2 search variable (bytes32), no ordering constraint
///   Each (counter, salt) pair produces a unique hash. The counter defines which
///   address space, the salt searches within it.
contract MiningPoolTest is Test {
    MiningPoolHarness public pool;

    address public player1;
    address public player2;

    // =========================================================================
    //                              SETUP
    // =========================================================================

    function setUp() public {
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        pool = new MiningPoolHarness(block.chainid);
    }

    // =========================================================================
    //                         HELPER FUNCTIONS
    // =========================================================================

    /// @notice Brute-force search for a salt that produces a valid share.
    ///         Iterates salt values until the CREATE2 hash has enough work.
    ///         With MIN_SHARE_WORK = 65,536, needs ~65,536 attempts on average.
    ///
    ///         Uses free-memory-pointer reset trick to avoid MemoryOOG — without it,
    ///         each abi.encodePacked allocates new memory, and ~65K iterations would
    ///         consume tens of MB (EVM memory cost is quadratic).
    ///
    ///         Looks up the dayHash from the pool. For days whose hash hasn't been
    ///         published yet (future days), use the overload that accepts an explicit dayHash.
    function _findValidSalt(address player, uint256 dayNumber, uint256 targetWork, uint256 counter, uint256 startSalt)
        internal
        view
        returns (bytes32 salt, uint256 actualWork)
    {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        return _findValidSaltWithDayHash(player, dayNumber, targetWork, counter, startSalt, dayHash);
    }

    /// @notice Overload that accepts an explicit dayHash. Used when testing submissions
    ///         on a day whose hash hasn't been published yet — the caller precomputes
    ///         the expected dayHash using the same formula as MiningPool._advanceDay().
    function _findValidSaltWithDayHash(
        address player,
        uint256 dayNumber,
        uint256 targetWork,
        uint256 counter,
        uint256 startSalt,
        bytes32 dayHash
    ) internal view returns (bytes32 salt, uint256 actualWork) {
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetWork, counter, dayHash);
        address poolAddr = address(pool);
        uint256 minWork = pool.MIN_SHARE_WORK();

        // Snapshot the free memory pointer — we reset it each iteration
        // so abi.encodePacked reuses the same scratch space.
        uint256 freeMemPtr;
        assembly { freeMemPtr := mload(0x40) }

        for (uint256 i = startSalt; i < startSalt + 10_000_000; i++) {
            salt = bytes32(i);
            bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), poolAddr, salt, initCodeHash));

            // Reset free memory pointer to prevent memory growth
            assembly { mstore(0x40, freeMemPtr) }

            actualWork = pool.hashToWork(create2Hash);
            if (actualWork >= minWork) {
                return (salt, actualWork);
            }
        }
        revert("_findValidSalt: exhausted search space");
    }

    function _findBelowMinSalt(address player, uint256 dayNumber, uint256 targetWork, uint256 counter)
        internal
        view
        returns (bytes32 salt)
    {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetWork, counter, dayHash);
        address poolAddr = address(pool);
        uint256 minWork = pool.MIN_SHARE_WORK();

        uint256 freeMemPtr;
        assembly { freeMemPtr := mload(0x40) }

        for (uint256 i = 0; i < 1_000_000; i++) {
            salt = bytes32(i);
            bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), poolAddr, salt, initCodeHash));
            assembly { mstore(0x40, freeMemPtr) }

            if (pool.hashToWork(create2Hash) < minWork) {
                return salt;
            }
        }
        revert("_findBelowMinSalt: exhausted search space");
    }

    function _minShareWork() internal view returns (uint256) {
        return pool.MIN_SHARE_WORK();
    }

    /// @notice Precompute the dayHash that MiningPool._advanceDay() will publish
    ///         for a given day. Uses the same formula: keccak256(pool, prevrandao, day).
    ///         Useful for finding valid salts BEFORE the day has been advanced on-chain.
    function _precomputeDayHash(uint256 dayNumber) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(pool), block.prevrandao, dayNumber));
    }

    /// @notice Submit a valid share as a given player. Convenience wrapper.
    ///         If the dayHash for the given day hasn't been published yet (e.g. when
    ///         submitting on a new day that triggers _advanceDay), this automatically
    ///         precomputes the expected dayHash using _precomputeDayHash().
    function _submitValidShare(address player, uint256 dayNumber, uint256 targetWork, uint256 counter)
        internal
        returns (bytes32 salt, uint256 actualWork)
    {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        if (dayHash == bytes32(0)) {
            // Day hash not published yet — precompute what _advanceDay will produce.
            dayHash = _precomputeDayHash(dayNumber);
        }
        (salt, actualWork) = _findValidSaltWithDayHash(player, dayNumber, targetWork, counter, 0, dayHash);
        // submitShare now requires msg.sender == player, so submit AS the player.
        // Every argument here is already a local, so the prank lands on submitShare —
        // see the hoists in the direct-call tests for the case where it wouldn't.
        vm.prank(player);
        pool.submitShare(player, targetWork, dayNumber, counter, salt);
    }

    // =========================================================================
    //                      CONSTRUCTOR TESTS
    // =========================================================================

    function test_constructor_setsDayZeroTimestamp() public view {
        assertEq(pool.dayZeroTimestamp(), block.timestamp);
    }

    function test_constructor_publishesDay0Hash() public view {
        bytes32 day0Hash = pool.dayHashes(0);
        assertTrue(day0Hash != bytes32(0), "Day 0 hash should be published");
    }

    function test_constructor_startsAtDay0() public view {
        assertEq(pool.currentDay(), 0);
        assertEq(pool.getCurrentDay(), 0);
    }

    function test_constructor_poolStartsWithBootstrapBaseline() public view {
        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT());
        assertEq(pool.totalIntegratedWork(), pool.BOOTSTRAP_INTEGRATED_WORK());
        assertEq(pool.getPoolScoreAt(0), pool.BOOTSTRAP_INTEGRATED_WORK());
    }

    // =========================================================================
    //                    BASIC SHARE SUBMISSION TESTS
    // =========================================================================

    function test_submitShare_validShare() public {
        (, uint256 actualWork) = _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);

        uint256 playerId = uint256(uint160(player1));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        assertTrue(playerScore > 0, "Player should have a score after valid share");

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 1);
        assertEq(pool.totalIntegratedWork(), pool.BOOTSTRAP_INTEGRATED_WORK() + actualWork);

        assertEq(pool.lastShareCounter(playerId, 0), 1);
    }

    function test_submitShare_emitsEvent() public {
        // Hoist MIN_SHARE_WORK into a local: the vm.prank() below must apply to
        // submitShare, but an inline pool.MIN_SHARE_WORK() argument would be the
        // "next call" and consume the prank instead, leaving submitShare unpranked.
        uint256 minWork = pool.MIN_SHARE_WORK();
        (bytes32 salt,) = _findValidSalt(player1, 0, minWork, 1, 0);
        uint256 playerId = uint256(uint160(player1));

        vm.expectEmit(true, true, false, false);
        emit MiningPool.ShareSubmitted(
            playerId,
            0,
            0,
            bytes32(0),
            0,
            0,
            0,
            false // data fields — not checked
        );

        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 1, salt);
    }

    function test_submitShare_multipleSharesSameDay() public {
        // counter=1, then counter=2 — different address spaces, independent salt search
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 2);

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 2);
        assertEq(pool.lastShareCounter(uint256(uint160(player1)), 0), 2);
    }

    function test_submitShare_twoPlayersIndependent() public {
        // Two players can use the same counter value — they have different address spaces
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player2, 0, pool.MIN_SHARE_WORK(), 1);

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 2);

        uint256 id1 = uint256(uint160(player1));
        uint256 id2 = uint256(uint160(player2));
        assertTrue(pool.getPlayerScoreAt(id1, 0) > 0);
        assertTrue(pool.getPlayerScoreAt(id2, 0) > 0);
    }

    function test_submitShare_anySaltWithValidCounter() public {
        // Salt is free — player can use any bytes32 value
        // Search for a valid salt starting from a large offset
        // Hoist MIN_SHARE_WORK into a local so the vm.prank() below lands on
        // submitShare rather than being consumed by an inline argument call.
        uint256 minWork = pool.MIN_SHARE_WORK();
        (bytes32 salt,) = _findValidSalt(player1, 0, minWork, 1, 5_000_000);

        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 1, salt);

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 1);
    }

    // =========================================================================
    //                    COUNTER ORDERING TESTS
    // =========================================================================

    function testRevert_submitShare_firstCounterZero() public {
        // Counter 0 is reserved as "nothing submitted yet" — the first share of a
        // day must use counter >= 1, so a counter-0 first submission must revert.
        uint256 minWork = _minShareWork();
        (bytes32 salt,) = _findValidSalt(player1, 0, minWork, 0, 0);
        vm.expectRevert(MiningPool.CounterNotIncreasing.selector);
        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 0, salt);
    }

    function testRevert_submitShare_counterNotIncreasing() public {
        uint256 minWork = _minShareWork();
        _submitValidShare(player1, 0, minWork, 1);

        // Try counter=1 again — should revert (must be strictly increasing)
        (bytes32 salt,) = _findValidSalt(player1, 0, minWork, 1, 999_999);
        vm.expectRevert(MiningPool.CounterNotIncreasing.selector);
        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 1, salt);
    }

    function testRevert_submitShare_counterLowerThanPrevious() public {
        uint256 minWork = _minShareWork();
        _submitValidShare(player1, 0, minWork, 5);

        // Try counter=3 (lower than 5) — should revert
        (bytes32 salt,) = _findValidSalt(player1, 0, minWork, 3, 0);
        vm.expectRevert(MiningPool.CounterNotIncreasing.selector);
        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 3, salt);
    }

    function test_submitShare_counterGapsAllowed() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1000); // gap from 1 to 1000

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 2);
        assertEq(pool.lastShareCounter(uint256(uint160(player1)), 0), 1000);
    }

    // =========================================================================
    //                       WORK VALIDATION TESTS
    // =========================================================================

    function testRevert_submitShare_belowMinWork() public {
        uint256 minWork = _minShareWork();
        bytes32 salt = _findBelowMinSalt(player1, 0, minWork, 1);

        vm.expectRevert(MiningPool.BelowMinWork.selector);
        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 1, salt);
    }

    function testRevert_submitShare_zeroPlayer() public {
        // The zero address has no usable identity — reverts up front with a clear
        // error rather than failing later in the PlayerNFT mint.
        // Note: read MIN_SHARE_WORK() into a local BEFORE expectRevert — otherwise the
        // arg-evaluation external call becomes the "next call" expectRevert watches.
        uint256 minWork = pool.MIN_SHARE_WORK();
        vm.expectRevert(MiningPool.ZeroPlayer.selector);
        pool.submitShare(address(0), minWork, 0, 1, bytes32(0));
    }

    function testRevert_submitShare_callerNotPlayer() public {
        // Shares are self-submitted: a caller cannot mine under someone else's
        // identity. player2 attempting to submit for player1 must revert.
        uint256 minWork = _minShareWork();
        (bytes32 salt,) = _findValidSalt(player1, 0, minWork, 1, 0);
        vm.expectRevert(MiningPool.CallerNotPlayer.selector);
        vm.prank(player2);
        pool.submitShare(player1, minWork, 0, 1, salt);
    }

    function test_submitShare_invalidShare_belowTarget() public {
        uint256 unreachableTargetWork = 1 << 128;
        uint256 player2Id = uint256(uint160(player2));

        // Build some pool state first
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        uint256 expectedAverage = pool.totalIntegratedWork() / pool.totalShareCount();
        uint256 maxCredit = pool.totalIntegratedWork() / pool.MAX_SHARE_CREDIT_DIVISOR();
        uint256 expectedCredit = expectedAverage < maxCredit ? expectedAverage : maxCredit;

        uint256 scoreBefore = pool.getPlayerScoreAt(player2Id, 0);
        (bytes32 salt,) = _findValidSalt(player2, 0, unreachableTargetWork, 1, 0);
        vm.prank(player2);
        pool.submitShare(player2, unreachableTargetWork, 0, 1, salt);
        uint256 scoreAfter = pool.getPlayerScoreAt(player2Id, 0);

        uint256 creditAwarded = scoreAfter - scoreBefore;
        assertEq(creditAwarded, expectedCredit, "Invalid share should get capped pool average");
    }

    // =========================================================================
    //                       CREDIT CALCULATION TESTS
    // =========================================================================

    function test_submitShare_firstShareEver_getsTargetCredit() public {
        uint256 playerId = uint256(uint160(player1));
        // Hoist MIN_SHARE_WORK into a local so the vm.prank() below lands on
        // submitShare rather than being consumed by an inline argument call.
        uint256 minWork = pool.MIN_SHARE_WORK();
        (bytes32 salt, uint256 actualWork) = _findValidSalt(player1, 0, minWork, 1, 0);

        vm.prank(player1);
        pool.submitShare(player1, minWork, 0, 1, salt);

        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        assertGe(actualWork, minWork);
        assertEq(playerScore, minWork, "First valid share credit = targetWork");
    }

    function test_submitShare_poolGetsFullActualWork() public {
        (, uint256 actualWork) = _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);

        assertEq(
            pool.totalIntegratedWork(),
            pool.BOOTSTRAP_INTEGRATED_WORK() + actualWork,
            "Pool should get full uncapped actual work"
        );
    }

    function test_submitShare_invalidShare_getsPoolAverage_multipleShares() public {
        // Build up pool with 3 valid shares from player1 (counters 1..3)
        for (uint256 i = 1; i <= 3; i++) {
            _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), i);
        }

        uint256 expectedAverage = pool.totalIntegratedWork() / pool.totalShareCount();
        uint256 maxCredit = pool.totalIntegratedWork() / pool.MAX_SHARE_CREDIT_DIVISOR();
        uint256 expectedCredit = expectedAverage < maxCredit ? expectedAverage : maxCredit;
        uint256 player2Id = uint256(uint160(player2));
        uint256 scoreBefore = pool.getPlayerScoreAt(player2Id, 0);

        uint256 unreachableTargetWork = 1 << 128;
        (bytes32 salt,) = _findValidSalt(player2, 0, unreachableTargetWork, 1, 0);
        vm.prank(player2);
        pool.submitShare(player2, unreachableTargetWork, 0, 1, salt);

        uint256 scoreAfter = pool.getPlayerScoreAt(player2Id, 0);
        assertEq(scoreAfter - scoreBefore, expectedCredit, "Invalid share credit should equal capped pool average");
    }

    function test_submitShare_invalidShare_creditCappedAtOnePercent() public {
        uint256 player2Id = uint256(uint160(player2));

        uint256 averageCredit = pool.totalIntegratedWork() / pool.totalShareCount();
        uint256 maxCredit = pool.totalIntegratedWork() / pool.MAX_SHARE_CREDIT_DIVISOR();
        assertGt(averageCredit, maxCredit, "test setup should expose cap");

        uint256 scoreBefore = pool.getPlayerScoreAt(player2Id, 0);
        uint256 unreachableTargetWork = 1 << 128;
        _submitValidShare(player2, 0, unreachableTargetWork, 1);
        uint256 scoreAfter = pool.getPlayerScoreAt(player2Id, 0);

        assertEq(scoreAfter - scoreBefore, maxCredit, "Invalid share credit should be capped");
    }

    // =========================================================================
    //          MATURE POOL CREDIT TESTS (combined participation + bonus)
    // =========================================================================
    //
    // During the 10-share bootstrap the pool average exceeds the cap, so every
    // credit is pinned to the cap. These tests seed totalShareCount > 100 (where
    // cap > average) via the harness to exercise the additive credit path
    // (average + target) and the single final cap. See MiningPoolHarness.

    /// @notice In a mature pool where average + target stays below the cap, a valid
    ///         share is credited the pool average PLUS its target work.
    function test_submitShare_maturePool_validShare_getsAveragePlusTarget() public {
        // 200 shares, 200,000,000 work -> average = 1,000,000, cap = 2,000,000.
        uint256 shareCount = 200;
        uint256 integratedWork = 200_000_000;
        pool.setPoolAggregates(shareCount, integratedWork);

        uint256 average = integratedWork / shareCount; // 1,000,000
        uint256 cap = integratedWork / pool.MAX_SHARE_CREDIT_DIVISOR(); // 2,000,000
        uint256 target = pool.MIN_SHARE_WORK(); // keeps the salt search cheap

        // average + target = 1,065,536 < cap, so the cap does NOT bind here.
        uint256 expectedCredit = average + target;
        assertLt(expectedCredit, cap, "test setup: combined credit should sit below the cap");

        uint256 playerId = uint256(uint160(player1));
        (bytes32 salt,) = _findValidSalt(player1, 0, target, 1, 0);
        vm.prank(player1);
        pool.submitShare(player1, target, 0, 1, salt);

        assertEq(
            pool.getPlayerScoreAt(playerId, 0),
            expectedCredit,
            "Valid share in mature pool = pool average + target work"
        );
    }

    /// @notice When average + target exceeds the cap, the COMBINED credit is capped
    ///         once at 1% of the pool — the participation and bonus terms can't stack
    ///         past the ceiling.
    function test_submitShare_maturePool_combinedCreditCappedAtOnePercent() public {
        // 200 shares, 6,553,600 work -> average = 32,768, cap = 65,536.
        // A valid share with target = MIN_SHARE_WORK (65,536) gives
        // average + target = 98,304 > cap, so it caps to 65,536.
        uint256 shareCount = 200;
        uint256 integratedWork = 6_553_600;
        pool.setPoolAggregates(shareCount, integratedWork);

        uint256 average = integratedWork / shareCount; // 32,768
        uint256 cap = integratedWork / pool.MAX_SHARE_CREDIT_DIVISOR(); // 65,536
        uint256 target = pool.MIN_SHARE_WORK(); // 65,536
        assertGt(average + target, cap, "test setup: combined credit should exceed the cap");

        uint256 playerId = uint256(uint160(player1));
        (bytes32 salt,) = _findValidSalt(player1, 0, target, 1, 0);
        vm.prank(player1);
        pool.submitShare(player1, target, 0, 1, salt);

        assertEq(pool.getPlayerScoreAt(playerId, 0), cap, "Combined credit capped at 1% of the pool");
    }

    /// @notice Anti-sandbag property: in identical pool state, a valid share must
    ///         score strictly more than an invalid one — so there is never a reason
    ///         to deliberately miss a target just to collect the bare average.
    function test_submitShare_maturePool_validScoresMoreThanInvalid() public {
        uint256 shareCount = 200;
        uint256 integratedWork = 200_000_000; // average = 1,000,000, cap = 2,000,000
        uint256 unreachableTarget = 1 << 128;
        uint256 player1Id = uint256(uint160(player1));
        uint256 player2Id = uint256(uint160(player2));

        // Invalid share (target unreachable -> actual < target): credit = min(average, cap).
        pool.setPoolAggregates(shareCount, integratedWork);
        (bytes32 invalidSalt,) = _findValidSalt(player2, 0, unreachableTarget, 1, 0);
        vm.prank(player2);
        pool.submitShare(player2, unreachableTarget, 0, 1, invalidSalt);
        uint256 invalidCredit = pool.getPlayerScoreAt(player2Id, 0);

        // Re-seed identical state, then a valid share: credit = min(average + target, cap).
        pool.setPoolAggregates(shareCount, integratedWork);
        uint256 target = pool.MIN_SHARE_WORK();
        (bytes32 validSalt,) = _findValidSalt(player1, 0, target, 1, 0);
        vm.prank(player1);
        pool.submitShare(player1, target, 0, 1, validSalt);
        uint256 validCredit = pool.getPlayerScoreAt(player1Id, 0);

        assertEq(invalidCredit, integratedWork / shareCount, "Invalid share = pool average (below cap here)");
        assertEq(validCredit, integratedWork / shareCount + target, "Valid share = pool average + target");
        assertGt(validCredit, invalidCredit, "Valid share must outscore an invalid one in the same pool");
    }

    // =========================================================================
    //                    DAY ADVANCEMENT TESTS
    // =========================================================================

    function test_dayAdvancement_timeWarpChangesDay() public view {
        assertEq(pool.getCurrentDay(), 0);
    }

    function test_dayAdvancement_warpToDay1() public {
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        assertEq(pool.getCurrentDay(), 1);
    }

    function test_dayAdvancement_submissionTriggersAdvance() public {
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitValidShare(player1, 1, pool.MIN_SHARE_WORK(), 1);

        assertEq(pool.currentDay(), 1);
        assertTrue(pool.dayHashes(1) != bytes32(0), "Day 1 hash should exist");
    }

    function test_dayAdvancement_snapshotsFrozenState() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        uint256 day0ShareCount = pool.totalShareCount();
        uint256 day0Work = pool.totalIntegratedWork();

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitValidShare(player1, 1, pool.MIN_SHARE_WORK(), 1);

        (uint256 snapShares, uint256 snapWork) = pool.daySnapshots(0);
        assertEq(snapShares, day0ShareCount, "Snapshot share count should match day 0 end");
        assertEq(snapWork, day0Work, "Snapshot work should match day 0 end");
    }

    function test_dayAdvancement_multiDayGap() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);

        vm.warp(pool.dayZeroTimestamp() + 5 days);
        _submitValidShare(player1, 5, pool.MIN_SHARE_WORK(), 1);

        assertEq(pool.currentDay(), 5);
        assertTrue(pool.dayHashes(5) != bytes32(0));

        // Skipped days have no hash (O(1) advancement)
        assertEq(pool.dayHashes(1), bytes32(0));
        assertEq(pool.dayHashes(2), bytes32(0));
        assertEq(pool.dayHashes(3), bytes32(0));
        assertEq(pool.dayHashes(4), bytes32(0));
    }

    function test_dayAdvancement_emitsDayAdvancedEvent() public {
        vm.warp(pool.dayZeroTimestamp() + 1 days);

        vm.expectEmit(true, false, false, false);
        emit MiningPool.DayAdvanced(1, bytes32(0));

        _submitValidShare(player1, 1, pool.MIN_SHARE_WORK(), 1);
    }

    // =========================================================================
    //                    DAY NUMBER VALIDATION TESTS
    // =========================================================================

    function testRevert_submitShare_futureDayNumber() public {
        uint256 minWork = _minShareWork();
        vm.expectRevert(MiningPool.InvalidDayNumber.selector);
        vm.prank(player1);
        pool.submitShare(player1, minWork, 1, 0, bytes32(uint256(42)));
    }

    function testRevert_submitShare_skippedDayNumber() public {
        vm.warp(pool.dayZeroTimestamp() + 5 days);
        _submitValidShare(player1, 5, pool.MIN_SHARE_WORK(), 1);

        // Day 3 was skipped — no hash exists
        uint256 minWork = _minShareWork();
        (bytes32 salt,) = _findValidSalt(player1, 3, minWork, 0, 0);
        vm.expectRevert(MiningPool.InvalidDayNumber.selector);
        vm.prank(player1);
        pool.submitShare(player1, minWork, 3, 0, salt);
    }

    // =========================================================================
    //                    CHECKPOINT / SCORE LOOKUP TESTS
    // =========================================================================

    function test_checkpoints_playerScoreCumulative() public {
        uint256 playerId = uint256(uint160(player1));

        for (uint256 i = 1; i <= 3; i++) {
            _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), i);
        }

        uint256 scoreAfter3 = pool.getPlayerScoreAt(playerId, 0);
        assertTrue(scoreAfter3 > 0, "Score should be positive after 3 shares");
    }

    function test_checkpoints_scoreAtPastDay() public {
        uint256 playerId = uint256(uint160(player1));

        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        uint256 day0Score = pool.getPlayerScoreAt(playerId, 0);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitValidShare(player1, 1, pool.MIN_SHARE_WORK(), 1);
        uint256 day1Score = pool.getPlayerScoreAt(playerId, 1);

        assertTrue(day1Score > day0Score, "Cumulative score should grow");
        assertEq(pool.getPlayerScoreAt(playerId, 0), day0Score, "Historical score preserved");
    }

    function test_checkpoints_poolScoreTracksAllPlayers() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player2, 0, pool.MIN_SHARE_WORK(), 1);

        uint256 id1 = uint256(uint160(player1));
        uint256 id2 = uint256(uint160(player2));

        uint256 poolScore = pool.getPoolScoreAt(0);
        uint256 p1Score = pool.getPlayerScoreAt(id1, 0);
        uint256 p2Score = pool.getPlayerScoreAt(id2, 0);

        assertEq(
            poolScore, p1Score + p2Score + pool.BOOTSTRAP_INTEGRATED_WORK(), "Pool score = player scores plus bootstrap"
        );
    }

    function test_checkpoints_lookupSkippedDayReturnsPrevious() public {
        uint256 playerId = uint256(uint160(player1));

        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        uint256 day0Score = pool.getPlayerScoreAt(playerId, 0);

        vm.warp(pool.dayZeroTimestamp() + 5 days);

        uint256 day3Score = pool.getPlayerScoreAt(playerId, 3);
        assertEq(day3Score, day0Score, "Skipped day lookup should return last known score");
    }

    /// @notice Characterization test for getPlayerScoreAt across many days with gaps.
    ///         A player submits on days 0, 2, 5 (counters reset per day). We then probe
    ///         every day 0..6 and assert the cumulative score is the most recent
    ///         checkpoint at-or-before each day — exactly the upperLookup contract.
    ///         Serves as a behavioral lock before swapping upperLookup ->
    ///         upperLookupRecent (which must return identical values).
    function test_checkpoints_playerLookupAcrossGaps() public {
        uint256 playerId = uint256(uint160(player1));
        uint256 zero = pool.dayZeroTimestamp();

        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        uint256 score0 = pool.getPlayerScoreAt(playerId, 0);

        vm.warp(zero + 2 days);
        _submitValidShare(player1, 2, pool.MIN_SHARE_WORK(), 1);
        uint256 score2 = pool.getPlayerScoreAt(playerId, 2);

        vm.warp(zero + 5 days);
        _submitValidShare(player1, 5, pool.MIN_SHARE_WORK(), 1);
        uint256 score5 = pool.getPlayerScoreAt(playerId, 5);

        // Active days strictly grow (each share adds a positive credit).
        assertGt(score2, score0, "score grows on day 2");
        assertGt(score5, score2, "score grows on day 5");

        // Probe the full range — gaps return the previous checkpoint, the tail holds.
        assertEq(pool.getPlayerScoreAt(playerId, 0), score0, "day 0");
        assertEq(pool.getPlayerScoreAt(playerId, 1), score0, "gap day 1 -> day 0");
        assertEq(pool.getPlayerScoreAt(playerId, 2), score2, "day 2");
        assertEq(pool.getPlayerScoreAt(playerId, 3), score2, "gap day 3 -> day 2");
        assertEq(pool.getPlayerScoreAt(playerId, 4), score2, "gap day 4 -> day 2");
        assertEq(pool.getPlayerScoreAt(playerId, 5), score5, "day 5");
        assertEq(pool.getPlayerScoreAt(playerId, 6), score5, "after last -> day 5");
    }

    /// @notice Characterization test tying getPoolScoreAt to getPlayerScoreAt across
    ///         days. With two players submitting on different days (incl. gaps), the
    ///         pool score at every day must equal the bootstrap seed plus the sum of
    ///         all player scores at that same day. Exercises both the pool-wide and
    ///         per-player upperLookup paths — another behavioral lock for the
    ///         upperLookupRecent swap.
    function test_checkpoints_poolScoreEqualsPlayerSumAcrossDays() public {
        uint256 p1 = uint256(uint160(player1));
        uint256 p2 = uint256(uint160(player2));
        uint256 bootstrap = pool.BOOTSTRAP_INTEGRATED_WORK();
        uint256 zero = pool.dayZeroTimestamp();

        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player2, 0, pool.MIN_SHARE_WORK(), 1);

        vm.warp(zero + 2 days);
        _submitValidShare(player1, 2, pool.MIN_SHARE_WORK(), 1);

        vm.warp(zero + 3 days);
        _submitValidShare(player2, 3, pool.MIN_SHARE_WORK(), 1);

        // Invariant holds at every day, including the gap (day 1) and past the last (day 4).
        for (uint256 d = 0; d <= 4; d++) {
            assertEq(
                pool.getPoolScoreAt(d),
                bootstrap + pool.getPlayerScoreAt(p1, d) + pool.getPlayerScoreAt(p2, d),
                "pool score = bootstrap + sum of player scores at every day"
            );
        }
    }

    // =========================================================================
    //                    CHAIN LOCK TESTS
    // =========================================================================

    function testRevert_constructor_wrongChain() public {
        vm.expectRevert();
        new MiningPool(999);
    }

    // =========================================================================
    //                    getInitCodeHash TESTS
    // =========================================================================

    function test_getInitCodeHash_deterministic() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        assertEq(hash1, hash2);
    }

    function test_getInitCodeHash_differentPlayers() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player2, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        assertTrue(hash1 != hash2, "Different players should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentDays() public view {
        // Different day numbers produce different initCodeHashes even with the same dayHash,
        // because dayNumber itself is encoded. In practice, different days also have
        // different dayHashes, further differentiating them.
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 1, pool.MIN_SHARE_WORK(), 0, dayHash);
        assertTrue(hash1 != hash2, "Different days should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentTargetWork() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, 32, 0, dayHash);
        assertTrue(hash1 != hash2, "Different difficulties should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentCounters() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 1, dayHash);
        assertTrue(hash1 != hash2, "Different counters should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentDayHashes() public view {
        // Same player, day, target work, and counter — but different dayHash values.
        // This is the core of the pre-computation prevention: without knowing
        // the dayHash, a player cannot predict the initCodeHash for a future day.
        bytes32 dayHash1 = pool.dayHashes(0);
        bytes32 dayHash2 = keccak256("different day hash");
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash1);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash2);
        assertTrue(hash1 != hash2, "Different dayHashes should get different initCodeHashes");
    }

    function test_computeVanityAddress_dayChoiceCommittedInAddress() public {
        bytes32 salt = bytes32(uint256(42));
        bytes32 day0Hash = pool.dayHashes(0);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        bytes32 day1Hash = pool.dayHashes(1);

        address day0Address = pool.computeVanityAddress(player1, 0, salt, 0, pool.MIN_SHARE_WORK(), day0Hash);
        address day1Address = pool.computeVanityAddress(player1, 0, salt, 1, pool.MIN_SHARE_WORK(), day1Hash);

        assertTrue(day0Address != day1Address, "Changing the day changes the CREATE2 address");
    }

    function test_getInitCodeHash_matchesManualComputation() public view {
        uint256 playerId = uint256(uint160(player1));
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 expected = keccak256(
            abi.encodePacked(
                type(CurrencyToken).creationCode,
                abi.encode(playerId, uint256(0), uint256(pool.MIN_SHARE_WORK()), uint256(0), dayHash)
            )
        );
        bytes32 actual = pool.getInitCodeHash(player1, 0, pool.MIN_SHARE_WORK(), 0, dayHash);
        assertEq(actual, expected, "Should match manual computation");
    }

    // =========================================================================
    //                    getPoolStats TESTS
    // =========================================================================

    // =========================================================================
    //                    getCurrentDayHash TESTS
    // =========================================================================

    function test_getCurrentDayHash_advancesDay() public {
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        assertEq(pool.currentDay(), 0, "Day should not advance until triggered");

        pool.getCurrentDayHash();

        assertEq(pool.currentDay(), 1);
        assertTrue(pool.dayHashes(1) != bytes32(0), "Day 1 hash should be published");
    }

    function test_getCurrentDayHash_idempotent() public {
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        bytes32 dayHash = pool.dayHashes(1);

        pool.getCurrentDayHash();
        assertEq(pool.dayHashes(1), dayHash, "Hash should not change on second call");
        assertEq(pool.currentDay(), 1);
    }

    function test_getCurrentDayHash_enablesMining() public {
        // Advance to day 1 via getCurrentDayHash (no share submission needed)
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();

        bytes32 dayHash = pool.dayHashes(1);
        assertTrue(dayHash != bytes32(0), "Day hash should be available");

        // Now mine using the published dayHash
        _submitValidShare(player1, 1, pool.MIN_SHARE_WORK(), 1);
        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 1, "Should accept share on published day");
    }

    // =========================================================================
    //                    getPoolStats TESTS
    // =========================================================================

    function test_getPoolStats_bootstrapOnly() public view {
        (uint256 shares, uint256 work, uint256 day, uint256 avg) = pool.getPoolStats();
        assertEq(shares, pool.BOOTSTRAP_SHARE_COUNT());
        assertEq(work, pool.BOOTSTRAP_INTEGRATED_WORK());
        assertEq(day, 0);
        assertEq(avg, pool.BOOTSTRAP_AVERAGE_WORK());
    }

    function test_getPoolStats_afterShares() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);

        (uint256 shares, uint256 work,, uint256 avg) = pool.getPoolStats();
        assertEq(shares, pool.BOOTSTRAP_SHARE_COUNT() + 1);
        assertTrue(
            work >= pool.BOOTSTRAP_INTEGRATED_WORK() + pool.MIN_SHARE_WORK(), "Work includes bootstrap plus share"
        );
        assertEq(avg, work / shares, "Average should use bootstrap and organic shares");
    }
}
