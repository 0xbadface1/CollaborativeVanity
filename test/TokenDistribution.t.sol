// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {PlayerNFT} from "../src/PlayerNFT.sol";
import {CurrencyToken} from "../src/CurrencyToken.sol";
import {LeadingZeros} from "../src/libraries/LeadingZeros.sol";

/// @title TokenDistributionTest
/// @notice Tests for Phase 2 token distribution.
///
/// FOUNDRY TESTING NOTES:
///   These tests intentionally build real MiningPool score history instead of
///   mocking score reads. That keeps the distribution math tied to the same
///   checkpoint behavior used by production claims.
///
///   Helpers that brute-force salts reset the free memory pointer each loop.
///   Without this, repeated abi.encodePacked calls grow EVM memory until Foundry
///   hits MemoryOOG on longer searches.
contract TokenDistributionTest is Test {
    using LeadingZeros for bytes32;

    MiningPool public pool;
    PlayerNFT public playerNFT;

    address public player1;
    address public player2;
    address public player3;

    uint256 public constant DISTRIBUTION_SUPPLY = 1_000_000 ether;
    uint256 public constant SECOND_DISTRIBUTION_SUPPLY = 2_500_000 ether;
    uint256 internal mockPlayerScore;
    uint256 internal mockPoolScore;

    function setUp() public {
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        player3 = makeAddr("player3");

        pool = new MiningPool(block.chainid);
        playerNFT = pool.playerNFT();
    }

    // =========================================================================
    //                              HELPERS
    // =========================================================================

    /// @notice Find a salt whose CREATE2 hash satisfies MIN_SHARE_DIFFICULTY.
    /// @param player Player address committed in CurrencyToken initCode
    /// @param dayNumber Day committed in CurrencyToken initCode
    /// @param targetDifficulty Target difficulty committed in CurrencyToken initCode
    /// @param counter Counter committed in CurrencyToken initCode
    /// @param startSalt First integer salt to try
    /// @param dayHash Day hash committed in CurrencyToken initCode
    /// @return salt Matching CREATE2 salt
    /// @return actualDifficulty Leading-zero difficulty of the matching hash
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

        uint256 freeMemPtr;
        assembly { freeMemPtr := mload(0x40) }

        for (uint256 i = startSalt; i < startSalt + 10_000_000; i++) {
            salt = bytes32(i);
            bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), poolAddr, salt, initCodeHash));
            assembly { mstore(0x40, freeMemPtr) }

            actualDifficulty = create2Hash.countLeadingZeroBits();
            if (actualDifficulty >= minDiff) {
                return (salt, actualDifficulty);
            }
        }

        revert("_findValidSaltWithDayHash: exhausted search space");
    }

    /// @notice Precompute the day hash that MiningPool will publish for a future day.
    /// @param dayNumber Day number to precompute
    /// @return The day hash MiningPool._advanceDay() will store
    function _precomputeDayHash(uint256 dayNumber) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(pool), block.prevrandao, dayNumber));
    }

    /// @notice Submit a valid share for any day, precomputing the day hash when needed.
    /// @param player Player receiving score credit
    /// @param dayNumber Day committed in CurrencyToken initCode
    /// @param counter Per-player day counter
    /// @param startSalt First integer salt to try
    function _submitShare(address player, uint256 dayNumber, uint256 counter, uint256 startSalt) internal {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        if (dayHash == bytes32(0)) {
            dayHash = _precomputeDayHash(dayNumber);
        }

        (bytes32 salt,) = _findValidSaltWithDayHash(player, dayNumber, 16, counter, startSalt, dayHash);
        pool.submitShare(player, 16, dayNumber, counter, salt);
    }

    /// @notice Submit a valid day-0 share with target difficulty 16.
    /// @param player Player receiving score credit
    /// @param counter Per-player day counter
    function _submitDay0Share(address player, uint256 counter) internal {
        (bytes32 salt,) = _findValidSaltWithDayHash(player, 0, 16, counter, counter * 1_000_000, pool.dayHashes(0));
        pool.submitShare(player, 16, 0, counter, salt);
    }

    /// @notice Build a known day-0 score snapshot: player1 has one share,
    ///         player2 has two shares, and the pool includes the bootstrap score.
    function _buildDay0Scores() internal {
        _submitDay0Share(player1, 0);
        _submitDay0Share(player2, 0);
        _submitDay0Share(player2, 1);
    }

    /// @notice Publish day 1 and register a day-1 discovery for player1.
    /// @param salt CREATE2 salt for the registered vanity address
    /// @return vanity Registered vanity address
    function _registerDay1Currency(bytes32 salt) internal returns (address vanity) {
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        vanity = pool.registerCurrency(player1, 100, salt, 1, 16);
    }

    /// @notice Register and deploy a day-1 currency with the standard test supply.
    /// @param salt CREATE2 salt for the registered vanity address
    /// @return token Deployed CurrencyToken
    /// @return vanity Registered vanity address
    function _deployDay1Currency(bytes32 salt) internal returns (CurrencyToken token, address vanity) {
        vanity = _registerDay1Currency(salt);
        vm.prank(player1);
        token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);
    }

    /// @notice Compute the actual leading-zero difficulty of a registered vanity address.
    /// @param player Player committed in CurrencyToken initCode
    /// @param dayNumber Day committed in CurrencyToken initCode
    /// @param targetDifficulty Target difficulty committed in CurrencyToken initCode
    /// @param counter Counter committed in CurrencyToken initCode
    /// @param salt CREATE2 salt
    /// @return Leading-zero difficulty of the CREATE2 hash
    function _vanityDifficulty(
        address player,
        uint256 dayNumber,
        uint256 targetDifficulty,
        uint256 counter,
        bytes32 salt
    ) internal view returns (uint256) {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetDifficulty, counter, dayHash);
        bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), address(pool), salt, initCodeHash));
        return create2Hash.countLeadingZeroBits();
    }

    /// @notice Mock MiningPool score read for directly deployed CurrencyToken tests.
    function getPlayerScoreAt(uint256, uint256) external view returns (uint256) {
        return mockPlayerScore;
    }

    /// @notice Mock MiningPool score read for directly deployed CurrencyToken tests.
    function getPoolScoreAt(uint256) external view returns (uint256) {
        return mockPoolScore;
    }

    // =========================================================================
    //                         INITIALIZATION TESTS
    // =========================================================================

    function test_deployCurrency_initializesDistribution() public {
        _buildDay0Scores();

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(500)));

        assertTrue(token.initialized(), "distribution initialized");
        assertEq(token.distributionSupply(), DISTRIBUTION_SUPPLY);
        assertEq(token.snapshotDay(), 0);
        assertEq(token.poolScoreAtSnapshot(), pool.getPoolScoreAt(0));
    }

    function testRevert_initializeDistribution_onlyMiningPool() public {
        _buildDay0Scores();
        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(501)));

        vm.expectRevert(CurrencyToken.OnlyMiningPool.selector);
        token.initializeDistribution(DISTRIBUTION_SUPPLY);
    }

    function testRevert_claim_beforeInitialized() public {
        CurrencyToken token = new CurrencyToken(uint256(uint160(player1)), 0, 16, 0, bytes32(uint256(123)));

        vm.expectRevert(CurrencyToken.DistributionNotInitialized.selector);
        token.claim(uint256(uint160(player1)));
    }

    function testRevert_deployCurrency_beforeSnapshotDayPasses() public {
        address vanity = pool.registerCurrency(player1, 0, bytes32(uint256(502)), 0, 16);

        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(MiningPool.DistributionSnapshotNotFrozen.selector, 0, 0));
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);
    }

    function testRevert_deployCurrency_zeroTotalSupply() public {
        address vanity = pool.registerCurrency(player1, 0, bytes32(uint256(503)), 0, 16);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player1);
        vm.expectRevert(MiningPool.ZeroTotalSupply.selector);
        pool.deployCurrency(vanity, 0);
    }

    // =========================================================================
    //                              CLAIM TESTS
    // =========================================================================

    function test_claim_discovererGetsProportionalPlusBonus() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player1));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        uint256 poolScore = pool.getPoolScoreAt(0);

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(504)));

        uint256 expectedProportional = DISTRIBUTION_SUPPLY * 99 * playerScore / (100 * poolScore);
        uint256 expectedBonus = DISTRIBUTION_SUPPLY / 100;
        uint256 claimed = token.claim(playerId);

        assertEq(claimed, expectedProportional + expectedBonus);
        assertEq(token.balanceOf(player1), expectedProportional + expectedBonus);
        assertTrue(token.claimed(playerId));
    }

    function test_claim_nonDiscovererGetsProportionalOnly() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player2));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        uint256 poolScore = pool.getPoolScoreAt(0);

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(505)));

        uint256 expected = DISTRIBUTION_SUPPLY * 99 * playerScore / (100 * poolScore);
        uint256 claimed = token.claim(playerId);

        assertEq(claimed, expected);
        assertEq(token.balanceOf(player2), expected);
    }

    function test_claim_mintsToCurrentPlayerNFTOwner() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player2));

        vm.prank(player2);
        playerNFT.transferFrom(player2, player3, playerId);

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(506)));
        uint256 claimed = token.claim(playerId);

        assertEq(token.balanceOf(player2), 0);
        assertEq(token.balanceOf(player3), claimed);
    }

    function testRevert_claim_cannotClaimTwice() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player1));

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(507)));
        token.claim(playerId);

        vm.expectRevert(abi.encodeWithSelector(CurrencyToken.AlreadyClaimed.selector, playerId));
        token.claim(playerId);
    }

    function testRevert_claim_zeroScoreNonDiscovererGetsNothing() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player3));
        pool.registerCurrency(player3, 0, bytes32(uint256(900)), 0, 16);

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(508)));

        vm.expectRevert(abi.encodeWithSelector(CurrencyToken.NothingToClaim.selector, playerId));
        token.claim(playerId);
    }

    function test_claim_allPlayersDoesNotExceedDistributionSupply() public {
        _buildDay0Scores();
        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(509)));

        token.claim(uint256(uint160(player1)));
        token.claim(uint256(uint160(player2)));

        assertLe(token.totalSupply(), DISTRIBUTION_SUPPLY);
    }

    function test_claim_scoresOnDiscoveryDayIgnored() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player2));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        uint256 poolScore = pool.getPoolScoreAt(0);

        address vanity = _registerDay1Currency(bytes32(uint256(510)));
        _submitShare(player2, 1, 0, 3_000_000);

        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        uint256 expected = DISTRIBUTION_SUPPLY * 99 * playerScore / (100 * poolScore);
        uint256 claimed = token.claim(playerId);

        assertEq(token.snapshotDay(), 0);
        assertEq(claimed, expected, "day-1 score must not affect day-1 discovery");
    }

    function test_claim_scoresAfterDiscoveryDayIgnored() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player2));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        uint256 poolScore = pool.getPoolScoreAt(0);

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(511)));

        vm.warp(pool.dayZeroTimestamp() + 2 days);
        _submitShare(player2, 2, 0, 4_000_000);

        uint256 expected = DISTRIBUTION_SUPPLY * 99 * playerScore / (100 * poolScore);
        uint256 claimed = token.claim(playerId);

        assertEq(token.snapshotDay(), 0);
        assertEq(claimed, expected, "post-discovery score must not affect distribution");
    }

    function test_claim_thirdPartyCanCall() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player1));

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(512)));

        vm.prank(player3);
        uint256 claimed = token.claim(playerId);

        assertEq(token.balanceOf(player1), claimed, "tokens mint to PlayerNFT owner");
        assertEq(token.balanceOf(player3), 0, "caller receives nothing");
    }

    function test_claim_usesFullPrecisionMulDivForLargeValues() public {
        _submitDay0Share(player1, 0);
        uint256 playerId = uint256(uint160(player1));
        uint256 hugeSupply = type(uint256).max / 99;
        mockPlayerScore = 1 << 200;
        mockPoolScore = mockPlayerScore;

        CurrencyToken token = new CurrencyToken(playerId, 0, 16, 0, pool.dayHashes(0));
        token.initializeDistribution(hugeSupply);

        uint256 expectedProportional = hugeSupply * 99 / 100;
        uint256 expectedBonus = hugeSupply / 100;
        uint256 claimed = token.claim(playerId);

        assertEq(claimed, expectedProportional + expectedBonus);
        assertEq(token.balanceOf(player1), claimed);
    }

    // =========================================================================
    //                          INTEGRATION TESTS
    // =========================================================================

    function test_fullFlow_multiPlayerMultiDay() public {
        _submitShare(player1, 0, 0, 0);
        _submitShare(player2, 0, 0, 1_000_000);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitShare(player1, 1, 0, 2_000_000);
        _submitShare(player2, 1, 0, 3_000_000);
        _submitShare(player3, 1, 0, 4_000_000);

        uint256 p1Id = uint256(uint160(player1));
        uint256 p2Id = uint256(uint160(player2));
        uint256 p3Id = uint256(uint160(player3));
        uint256 snapshotDay = 1;
        uint256 p1Score = pool.getPlayerScoreAt(p1Id, snapshotDay);
        uint256 p2Score = pool.getPlayerScoreAt(p2Id, snapshotDay);
        uint256 p3Score = pool.getPlayerScoreAt(p3Id, snapshotDay);
        uint256 poolScore = pool.getPoolScoreAt(snapshotDay);

        vm.warp(pool.dayZeroTimestamp() + 2 days);
        pool.getCurrentDayHash();
        address vanity = pool.registerCurrency(player1, 200, bytes32(uint256(513)), 2, 16);

        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        uint256 p1Expected = DISTRIBUTION_SUPPLY * 99 * p1Score / (100 * poolScore) + DISTRIBUTION_SUPPLY / 100;
        uint256 p2Expected = DISTRIBUTION_SUPPLY * 99 * p2Score / (100 * poolScore);
        uint256 p3Expected = DISTRIBUTION_SUPPLY * 99 * p3Score / (100 * poolScore);

        assertEq(token.claim(p1Id), p1Expected);
        assertEq(token.claim(p2Id), p2Expected);
        assertEq(token.claim(p3Id), p3Expected);
        assertEq(token.balanceOf(player1), p1Expected);
        assertEq(token.balanceOf(player2), p2Expected);
        assertEq(token.balanceOf(player3), p3Expected);
    }

    function test_fullFlow_multipleCurrencies() public {
        _buildDay0Scores();

        uint256 p2Id = uint256(uint160(player2));
        uint256 p3Id = uint256(uint160(player3));
        uint256 currencyOneP2Score = pool.getPlayerScoreAt(p2Id, 0);
        uint256 currencyOnePoolScore = pool.getPoolScoreAt(0);

        (CurrencyToken tokenOne,) = _deployDay1Currency(bytes32(uint256(514)));

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitShare(player3, 1, 0, 5_000_000);

        uint256 currencyTwoP2Score = pool.getPlayerScoreAt(p2Id, 1);
        uint256 currencyTwoP3Score = pool.getPlayerScoreAt(p3Id, 1);
        uint256 currencyTwoPoolScore = pool.getPoolScoreAt(1);

        vm.warp(pool.dayZeroTimestamp() + 2 days);
        pool.getCurrentDayHash();
        address vanityTwo = pool.registerCurrency(player2, 300, bytes32(uint256(515)), 2, 16);

        vm.prank(player2);
        CurrencyToken tokenTwo = pool.deployCurrency(vanityTwo, SECOND_DISTRIBUTION_SUPPLY);

        uint256 tokenOneP2Expected = DISTRIBUTION_SUPPLY * 99 * currencyOneP2Score / (100 * currencyOnePoolScore);
        uint256 tokenTwoP2Expected = SECOND_DISTRIBUTION_SUPPLY * 99 * currencyTwoP2Score
            / (100 * currencyTwoPoolScore) + SECOND_DISTRIBUTION_SUPPLY / 100;
        uint256 tokenTwoP3Expected = SECOND_DISTRIBUTION_SUPPLY * 99 * currencyTwoP3Score
            / (100 * currencyTwoPoolScore);

        assertEq(tokenOne.claim(p2Id), tokenOneP2Expected);
        assertEq(tokenOne.balanceOf(player2), tokenOneP2Expected);

        assertEq(tokenTwo.claim(p2Id), tokenTwoP2Expected);
        assertEq(tokenTwo.claim(p3Id), tokenTwoP3Expected);
        assertEq(tokenTwo.balanceOf(player2), tokenTwoP2Expected);
        assertEq(tokenTwo.balanceOf(player3), tokenTwoP3Expected);

        vm.expectRevert(abi.encodeWithSelector(CurrencyToken.NothingToClaim.selector, p3Id));
        tokenOne.claim(p3Id);
    }

    // =========================================================================
    //                          AUTO-BOOST TESTS
    // =========================================================================

    function test_deployCurrency_autoBoostsIntegratedDifficultyOnly() public {
        _buildDay0Scores();
        bytes32 salt = bytes32(uint256(516));
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        uint256 difficulty = _vanityDifficulty(player1, 1, 16, 100, salt);

        uint256 difficultyBefore = pool.totalIntegratedDifficulty();
        uint256 shareCountBefore = pool.totalShareCount();
        uint256 poolScoreBefore = pool.getPoolScoreAt(0);

        address vanity = pool.registerCurrency(player1, 100, salt, 1, 16);
        vm.prank(player1);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        assertEq(pool.totalIntegratedDifficulty(), difficultyBefore + difficulty);
        assertEq(pool.totalShareCount(), shareCountBefore, "auto-boost must not add a share");
        assertEq(pool.getPoolScoreAt(0), poolScoreBefore, "auto-boost must not alter checkpoints");
    }
}
