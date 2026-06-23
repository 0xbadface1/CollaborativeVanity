// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {CurrencyToken} from "../src/CurrencyToken.sol";
import {LeadingZeros} from "../src/libraries/LeadingZeros.sol";

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
    using LeadingZeros for bytes32;

    MiningPool public pool;

    address public player1;
    address public player2;

    // =========================================================================
    //                              SETUP
    // =========================================================================

    function setUp() public {
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        pool = new MiningPool(block.chainid);
    }

    // =========================================================================
    //                         HELPER FUNCTIONS
    // =========================================================================

    /// @notice Brute-force search for a salt that produces a valid share.
    ///         Iterates salt values until the CREATE2 hash has enough leading zeros.
    ///         With MIN_SHARE_DIFFICULTY = 16, needs ~65,536 attempts on average.
    ///
    ///         Uses free-memory-pointer reset trick to avoid MemoryOOG — without it,
    ///         each abi.encodePacked allocates new memory, and ~65K iterations would
    ///         consume tens of MB (EVM memory cost is quadratic).
    ///
    ///         Looks up the dayHash from the pool. For days whose hash hasn't been
    ///         published yet (future days), use the overload that accepts an explicit dayHash.
    function _findValidSalt(
        address player,
        uint256 dayNumber,
        uint256 targetDifficulty,
        uint256 counter,
        uint256 startSalt
    ) internal view returns (bytes32 salt, uint256 actualDifficulty) {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        return _findValidSaltWithDayHash(player, dayNumber, targetDifficulty, counter, startSalt, dayHash);
    }

    /// @notice Overload that accepts an explicit dayHash. Used when testing submissions
    ///         on a day whose hash hasn't been published yet — the caller precomputes
    ///         the expected dayHash using the same formula as MiningPool._advanceDay().
    function _findValidSaltWithDayHash(
        address player,
        uint256 dayNumber,
        uint256 targetDifficulty,
        uint256 counter,
        uint256 startSalt,
        bytes32 dayHash
    ) internal view returns (bytes32 salt, uint256 actualDifficulty) {
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetDifficulty, counter, dayHash);
        address poolAddr = address(pool);
        uint256 minDiff = pool.MIN_SHARE_DIFFICULTY();

        // Snapshot the free memory pointer — we reset it each iteration
        // so abi.encodePacked reuses the same scratch space.
        uint256 freeMemPtr;
        assembly { freeMemPtr := mload(0x40) }

        for (uint256 i = startSalt; i < startSalt + 10_000_000; i++) {
            salt = bytes32(i);
            bytes32 create2Hash = keccak256(abi.encodePacked(
                bytes1(0xff),
                poolAddr,
                salt,
                initCodeHash
            ));

            // Reset free memory pointer to prevent memory growth
            assembly { mstore(0x40, freeMemPtr) }

            actualDifficulty = create2Hash.countLeadingZeroBits();
            if (actualDifficulty >= minDiff) {
                return (salt, actualDifficulty);
            }
        }
        revert("_findValidSalt: exhausted search space");
    }

    /// @notice Precompute the dayHash that MiningPool._advanceDay() will publish
    ///         for a given day. Uses the same formula: keccak256(pool, prevrandao, day).
    ///         Useful for finding valid salts BEFORE the day has been advanced on-chain.
    function _precomputeDayHash(uint256 dayNumber) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(
            address(pool),
            block.prevrandao,
            dayNumber
        ));
    }

    /// @notice Submit a valid share as a given player. Convenience wrapper.
    ///         If the dayHash for the given day hasn't been published yet (e.g. when
    ///         submitting on a new day that triggers _advanceDay), this automatically
    ///         precomputes the expected dayHash using _precomputeDayHash().
    function _submitValidShare(
        address player,
        uint256 dayNumber,
        uint256 targetDifficulty,
        uint256 counter
    ) internal returns (bytes32 salt, uint256 actualDifficulty) {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        if (dayHash == bytes32(0)) {
            // Day hash not published yet — precompute what _advanceDay will produce.
            dayHash = _precomputeDayHash(dayNumber);
        }
        (salt, actualDifficulty) = _findValidSaltWithDayHash(
            player, dayNumber, targetDifficulty, counter, 0, dayHash
        );
        pool.submitShare(player, targetDifficulty, dayNumber, counter, salt);
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
        assertEq(pool.totalIntegratedDifficulty(), pool.BOOTSTRAP_INTEGRATED_DIFFICULTY());
        assertEq(pool.getPoolScoreAt(0), pool.BOOTSTRAP_INTEGRATED_DIFFICULTY());
    }

    // =========================================================================
    //                    BASIC SHARE SUBMISSION TESTS
    // =========================================================================

    function test_submitShare_validShare() public {
        (, uint256 actualDifficulty) = _submitValidShare(player1, 0, 16, 0);

        uint256 playerId = uint256(uint160(player1));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        assertTrue(playerScore > 0, "Player should have a score after valid share");

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 1);
        assertEq(pool.totalIntegratedDifficulty(), pool.BOOTSTRAP_INTEGRATED_DIFFICULTY() + actualDifficulty);

        assertTrue(pool.hasSubmittedOnDay(playerId, 0));
        assertEq(pool.lastShareCounter(playerId, 0), 0);
    }

    function test_submitShare_emitsEvent() public {
        (bytes32 salt,) = _findValidSalt(player1, 0, 16, 0, 0);
        uint256 playerId = uint256(uint160(player1));

        vm.expectEmit(true, true, false, false);
        emit MiningPool.ShareSubmitted(
            playerId, 0,
            0, bytes32(0), 0, 0, 0, false // data fields — not checked
        );

        pool.submitShare(player1, 16, 0, 0, salt);
    }

    function test_submitShare_multipleSharesSameDay() public {
        // counter=0, then counter=1 — different address spaces, independent salt search
        _submitValidShare(player1, 0, 16, 0);
        _submitValidShare(player1, 0, 16, 1);

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 2);
        assertEq(pool.lastShareCounter(uint256(uint160(player1)), 0), 1);
    }

    function test_submitShare_twoPlayersIndependent() public {
        // Two players can use the same counter value — they have different address spaces
        _submitValidShare(player1, 0, 16, 0);
        _submitValidShare(player2, 0, 16, 0);

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 2);

        uint256 id1 = uint256(uint160(player1));
        uint256 id2 = uint256(uint160(player2));
        assertTrue(pool.getPlayerScoreAt(id1, 0) > 0);
        assertTrue(pool.getPlayerScoreAt(id2, 0) > 0);
    }

    function test_submitShare_anySaltWithValidCounter() public {
        // Salt is free — player can use any bytes32 value
        // Search for a valid salt starting from a large offset
        (bytes32 salt,) = _findValidSalt(player1, 0, 16, 0, 5_000_000);

        pool.submitShare(player1, 16, 0, 0, salt);

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 1);
    }

    // =========================================================================
    //                    COUNTER ORDERING TESTS
    // =========================================================================

    function testRevert_submitShare_counterNotIncreasing() public {
        _submitValidShare(player1, 0, 16, 0);

        // Try counter=0 again — should revert (must be strictly increasing)
        (bytes32 salt,) = _findValidSalt(player1, 0, 16, 0, 999_999);
        vm.expectRevert(MiningPool.CounterNotIncreasing.selector);
        pool.submitShare(player1, 16, 0, 0, salt);
    }

    function testRevert_submitShare_counterLowerThanPrevious() public {
        _submitValidShare(player1, 0, 16, 5);

        // Try counter=3 (lower than 5) — should revert
        (bytes32 salt,) = _findValidSalt(player1, 0, 16, 3, 0);
        vm.expectRevert(MiningPool.CounterNotIncreasing.selector);
        pool.submitShare(player1, 16, 0, 3, salt);
    }

    function test_submitShare_counterGapsAllowed() public {
        _submitValidShare(player1, 0, 16, 0);
        _submitValidShare(player1, 0, 16, 1000); // gap from 0 to 1000

        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 2);
        assertEq(pool.lastShareCounter(uint256(uint160(player1)), 0), 1000);
    }

    // =========================================================================
    //                    DIFFICULTY VALIDATION TESTS
    // =========================================================================

    function testRevert_submitShare_belowMinDifficulty() public {
        // A random salt will almost certainly produce < 16 leading zeros
        vm.expectRevert(MiningPool.BelowMinDifficulty.selector);
        pool.submitShare(player1, 16, 0, 0, bytes32(uint256(42)));
    }

    function test_submitShare_invalidShare_belowTarget() public {
        // target=200 — any found salt will have actual difficulty ~16-25, far below 200
        uint256 player2Id = uint256(uint160(player2));

        // Build some pool state first
        _submitValidShare(player1, 0, 16, 0);
        uint256 expectedAverage = pool.totalIntegratedDifficulty() / pool.totalShareCount();
        uint256 maxCredit = pool.totalIntegratedDifficulty() / pool.MAX_SHARE_CREDIT_DIVISOR();
        uint256 expectedCredit = expectedAverage < maxCredit ? expectedAverage : maxCredit;

        uint256 scoreBefore = pool.getPlayerScoreAt(player2Id, 0);
        (bytes32 salt,) = _findValidSalt(player2, 0, 200, 0, 0);
        pool.submitShare(player2, 200, 0, 0, salt);
        uint256 scoreAfter = pool.getPlayerScoreAt(player2Id, 0);

        uint256 creditAwarded = scoreAfter - scoreBefore;
        assertEq(creditAwarded, expectedCredit, "Invalid share should get capped pool average");
    }

    // =========================================================================
    //                       CREDIT CALCULATION TESTS
    // =========================================================================

    function test_submitShare_firstShareEver_getsTargetCredit() public {
        uint256 playerId = uint256(uint160(player1));
        (bytes32 salt, uint256 actualDifficulty) = _findValidSalt(player1, 0, 16, 0, 0);

        pool.submitShare(player1, 16, 0, 0, salt);

        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        if (actualDifficulty >= 16) {
            assertEq(playerScore, 16, "First valid share credit = targetDifficulty");
        }
    }

    function test_submitShare_poolGetsFullActualDifficulty() public {
        (, uint256 actualDiff) = _submitValidShare(player1, 0, 16, 0);

        assertEq(
            pool.totalIntegratedDifficulty(),
            pool.BOOTSTRAP_INTEGRATED_DIFFICULTY() + actualDiff,
            "Pool should get full uncapped actual difficulty"
        );
    }

    function test_submitShare_invalidShare_getsPoolAverage_multipleShares() public {
        // Build up pool with 3 valid shares from player1
        for (uint256 i = 0; i < 3; i++) {
            _submitValidShare(player1, 0, 16, i);
        }

        uint256 expectedAverage = pool.totalIntegratedDifficulty() / pool.totalShareCount();
        uint256 maxCredit = pool.totalIntegratedDifficulty() / pool.MAX_SHARE_CREDIT_DIVISOR();
        uint256 expectedCredit = expectedAverage < maxCredit ? expectedAverage : maxCredit;
        uint256 player2Id = uint256(uint160(player2));
        uint256 scoreBefore = pool.getPlayerScoreAt(player2Id, 0);

        // Submit invalid share as player2 (target=200, actual will be ~16)
        (bytes32 salt,) = _findValidSalt(player2, 0, 200, 0, 0);
        pool.submitShare(player2, 200, 0, 0, salt);

        uint256 scoreAfter = pool.getPlayerScoreAt(player2Id, 0);
        assertEq(
            scoreAfter - scoreBefore,
            expectedCredit,
            "Invalid share credit should equal capped pool average"
        );
    }

    function test_submitShare_invalidShare_creditCappedAtOnePercent() public {
        uint256 player2Id = uint256(uint160(player2));

        uint256 averageCredit = pool.totalIntegratedDifficulty() / pool.totalShareCount();
        uint256 maxCredit = pool.totalIntegratedDifficulty() / pool.MAX_SHARE_CREDIT_DIVISOR();
        assertGt(averageCredit, maxCredit, "test setup should expose cap");

        uint256 scoreBefore = pool.getPlayerScoreAt(player2Id, 0);
        _submitValidShare(player2, 0, 200, 0);
        uint256 scoreAfter = pool.getPlayerScoreAt(player2Id, 0);

        assertEq(scoreAfter - scoreBefore, maxCredit, "Invalid share credit should be capped");
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
        _submitValidShare(player1, 1, 16, 0);

        assertEq(pool.currentDay(), 1);
        assertTrue(pool.dayHashes(1) != bytes32(0), "Day 1 hash should exist");
    }

    function test_dayAdvancement_snapshotsFrozenState() public {
        _submitValidShare(player1, 0, 16, 0);
        uint256 day0ShareCount = pool.totalShareCount();
        uint256 day0Difficulty = pool.totalIntegratedDifficulty();

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitValidShare(player1, 1, 16, 0);

        (uint256 snapShares, uint256 snapDifficulty) = pool.daySnapshots(0);
        assertEq(snapShares, day0ShareCount, "Snapshot share count should match day 0 end");
        assertEq(snapDifficulty, day0Difficulty, "Snapshot difficulty should match day 0 end");
    }

    function test_dayAdvancement_multiDayGap() public {
        _submitValidShare(player1, 0, 16, 0);

        vm.warp(pool.dayZeroTimestamp() + 5 days);
        _submitValidShare(player1, 5, 16, 0);

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

        _submitValidShare(player1, 1, 16, 0);
    }

    // =========================================================================
    //                    DAY NUMBER VALIDATION TESTS
    // =========================================================================

    function testRevert_submitShare_futureDayNumber() public {
        vm.expectRevert(MiningPool.InvalidDayNumber.selector);
        pool.submitShare(player1, 16, 1, 0, bytes32(uint256(42)));
    }

    function testRevert_submitShare_skippedDayNumber() public {
        vm.warp(pool.dayZeroTimestamp() + 5 days);
        _submitValidShare(player1, 5, 16, 0);

        // Day 3 was skipped — no hash exists
        (bytes32 salt,) = _findValidSalt(player1, 3, 16, 0, 0);
        vm.expectRevert(MiningPool.InvalidDayNumber.selector);
        pool.submitShare(player1, 16, 3, 0, salt);
    }

    // =========================================================================
    //                    CHECKPOINT / SCORE LOOKUP TESTS
    // =========================================================================

    function test_checkpoints_playerScoreCumulative() public {
        uint256 playerId = uint256(uint160(player1));

        for (uint256 i = 0; i < 3; i++) {
            _submitValidShare(player1, 0, 16, i);
        }

        uint256 scoreAfter3 = pool.getPlayerScoreAt(playerId, 0);
        assertTrue(scoreAfter3 > 0, "Score should be positive after 3 shares");
    }

    function test_checkpoints_scoreAtPastDay() public {
        uint256 playerId = uint256(uint160(player1));

        _submitValidShare(player1, 0, 16, 0);
        uint256 day0Score = pool.getPlayerScoreAt(playerId, 0);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitValidShare(player1, 1, 16, 0);
        uint256 day1Score = pool.getPlayerScoreAt(playerId, 1);

        assertTrue(day1Score > day0Score, "Cumulative score should grow");
        assertEq(pool.getPlayerScoreAt(playerId, 0), day0Score, "Historical score preserved");
    }

    function test_checkpoints_poolScoreTracksAllPlayers() public {
        _submitValidShare(player1, 0, 16, 0);
        _submitValidShare(player2, 0, 16, 0);

        uint256 id1 = uint256(uint160(player1));
        uint256 id2 = uint256(uint160(player2));

        uint256 poolScore = pool.getPoolScoreAt(0);
        uint256 p1Score = pool.getPlayerScoreAt(id1, 0);
        uint256 p2Score = pool.getPlayerScoreAt(id2, 0);

        assertEq(
            poolScore,
            p1Score + p2Score + pool.BOOTSTRAP_INTEGRATED_DIFFICULTY(),
            "Pool score = player scores plus bootstrap"
        );
    }

    function test_checkpoints_lookupSkippedDayReturnsPrevious() public {
        uint256 playerId = uint256(uint160(player1));

        _submitValidShare(player1, 0, 16, 0);
        uint256 day0Score = pool.getPlayerScoreAt(playerId, 0);

        vm.warp(pool.dayZeroTimestamp() + 5 days);

        uint256 day3Score = pool.getPlayerScoreAt(playerId, 3);
        assertEq(day3Score, day0Score, "Skipped day lookup should return last known score");
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
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
        assertEq(hash1, hash2);
    }

    function test_getInitCodeHash_differentPlayers() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player2, 0, 16, 0, dayHash);
        assertTrue(hash1 != hash2, "Different players should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentDays() public view {
        // Different day numbers produce different initCodeHashes even with the same dayHash,
        // because dayNumber itself is encoded. In practice, different days also have
        // different dayHashes, further differentiating them.
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 1, 16, 0, dayHash);
        assertTrue(hash1 != hash2, "Different days should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentDifficulties() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, 32, 0, dayHash);
        assertTrue(hash1 != hash2, "Different difficulties should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentCounters() public view {
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, 16, 1, dayHash);
        assertTrue(hash1 != hash2, "Different counters should get different initCodeHashes");
    }

    function test_getInitCodeHash_differentDayHashes() public view {
        // Same player, day, difficulty, and counter — but different dayHash values.
        // This is the core of the pre-computation prevention: without knowing
        // the dayHash, a player cannot predict the initCodeHash for a future day.
        bytes32 dayHash1 = pool.dayHashes(0);
        bytes32 dayHash2 = keccak256("different day hash");
        bytes32 hash1 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash1);
        bytes32 hash2 = pool.getInitCodeHash(player1, 0, 16, 0, dayHash2);
        assertTrue(hash1 != hash2, "Different dayHashes should get different initCodeHashes");
    }

    function test_computeVanityAddress_dayChoiceCommittedInAddress() public {
        bytes32 salt = bytes32(uint256(42));
        bytes32 day0Hash = pool.dayHashes(0);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        bytes32 day1Hash = pool.dayHashes(1);

        address day0Address = pool.computeVanityAddress(player1, 0, salt, 0, 16, day0Hash);
        address day1Address = pool.computeVanityAddress(player1, 0, salt, 1, 16, day1Hash);

        assertTrue(day0Address != day1Address, "Changing the day changes the CREATE2 address");
    }

    function test_getInitCodeHash_matchesManualComputation() public view {
        uint256 playerId = uint256(uint160(player1));
        bytes32 dayHash = pool.dayHashes(0);
        bytes32 expected = keccak256(abi.encodePacked(
            type(CurrencyToken).creationCode,
            abi.encode(playerId, uint256(0), uint256(16), uint256(0), dayHash)
        ));
        bytes32 actual = pool.getInitCodeHash(player1, 0, 16, 0, dayHash);
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
        _submitValidShare(player1, 1, 16, 0);
        assertEq(pool.totalShareCount(), pool.BOOTSTRAP_SHARE_COUNT() + 1, "Should accept share on published day");
    }

    // =========================================================================
    //                    getPoolStats TESTS
    // =========================================================================

    function test_getPoolStats_bootstrapOnly() public view {
        (uint256 shares, uint256 difficulty, uint256 day, uint256 avg) = pool.getPoolStats();
        assertEq(shares, pool.BOOTSTRAP_SHARE_COUNT());
        assertEq(difficulty, pool.BOOTSTRAP_INTEGRATED_DIFFICULTY());
        assertEq(day, 0);
        assertEq(avg, pool.BOOTSTRAP_AVERAGE_DIFFICULTY());
    }

    function test_getPoolStats_afterShares() public {
        _submitValidShare(player1, 0, 16, 0);

        (uint256 shares, uint256 difficulty,, uint256 avg) = pool.getPoolStats();
        assertEq(shares, pool.BOOTSTRAP_SHARE_COUNT() + 1);
        assertTrue(difficulty >= pool.BOOTSTRAP_INTEGRATED_DIFFICULTY() + 16, "Difficulty includes bootstrap plus share");
        assertEq(avg, difficulty / shares, "Average should use bootstrap and organic shares");
    }
}
