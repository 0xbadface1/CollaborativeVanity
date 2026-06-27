// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {stdError} from "forge-std/StdError.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {PlayerNFT} from "../src/PlayerNFT.sol";
import {CurrencyToken} from "../src/CurrencyToken.sol";

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

    /// @notice Find a salt whose CREATE2 hash satisfies MIN_SHARE_WORK.
    /// @param player Player address committed in CurrencyToken initCode
    /// @param dayNumber Day committed in CurrencyToken initCode
    /// @param targetWork Target work committed in CurrencyToken initCode
    /// @param counter Counter committed in CurrencyToken initCode
    /// @param startSalt First integer salt to try
    /// @param dayHash Day hash committed in CurrencyToken initCode
    /// @return salt Matching CREATE2 salt
    /// @return actualWork Expected work of the matching hash
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

        uint256 freeMemPtr;
        assembly { freeMemPtr := mload(0x40) }

        for (uint256 i = startSalt; i < startSalt + 10_000_000; i++) {
            salt = bytes32(i);
            bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), poolAddr, salt, initCodeHash));
            assembly { mstore(0x40, freeMemPtr) }

            actualWork = pool.addressToWork(address(uint160(uint256(create2Hash))));
            if (actualWork >= minWork) {
                return (salt, actualWork);
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

        // Read MIN_SHARE_WORK into a local first: submitShare requires
        // msg.sender == player, and the vm.prank() below must apply to submitShare.
        // An inline pool.MIN_SHARE_WORK() argument would be the "next call" and
        // consume the prank, leaving submitShare unpranked and reverting.
        uint256 minWork = pool.MIN_SHARE_WORK();
        (bytes32 salt,) = _findValidSaltWithDayHash(player, dayNumber, minWork, counter, startSalt, dayHash);
        vm.prank(player);
        pool.submitShare(player, minWork, dayNumber, counter, salt);
    }

    /// @notice Submit a valid day-0 share with the minimum target work.
    /// @param player Player receiving score credit
    /// @param counter Per-player day counter
    function _submitDay0Share(address player, uint256 counter) internal {
        // Local MIN_SHARE_WORK so the vm.prank() lands on submitShare — an inline
        // pool.MIN_SHARE_WORK() argument would consume the prank (see _submitShare).
        uint256 minWork = pool.MIN_SHARE_WORK();
        (bytes32 salt,) =
            _findValidSaltWithDayHash(player, 0, minWork, counter, counter * 1_000_000, pool.dayHashes(0));
        vm.prank(player);
        pool.submitShare(player, minWork, 0, counter, salt);
    }

    /// @notice Build a known day-0 score snapshot: player1 has one share,
    ///         player2 has two shares, and the pool includes the bootstrap score.
    function _buildDay0Scores() internal {
        _submitDay0Share(player1, 1);
        _submitDay0Share(player2, 1);
        _submitDay0Share(player2, 2);
    }

    /// @notice Publish day 1 and register a day-1 discovery for player1.
    /// @param salt CREATE2 salt for the registered vanity address
    /// @return vanity Registered vanity address
    function _registerDay1Currency(bytes32 salt) internal returns (address vanity) {
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        vanity = _registerCurrency(player1, 100, salt, 1, pool.MIN_SHARE_WORK());
    }

    /// @notice Register a currency as `player`, pranking so msg.sender matches the
    ///         player identity. Arguments are evaluated by the caller before the prank,
    ///         so an inline `pool.MIN_SHARE_WORK()` argument cannot consume it.
    function _registerCurrency(
        address player,
        uint256 counter,
        bytes32 salt,
        uint256 dayNumber,
        uint256 targetWork
    ) internal returns (address vanityAddress) {
        vm.prank(player);
        vanityAddress = pool.registerCurrency(player, counter, salt, dayNumber, targetWork);
    }

    /// @notice Claim a currency allocation as the current PlayerNFT owner. Resolves the
    ///         owner of `claimPlayerId` and pranks so msg.sender matches that owner.
    function _claim(CurrencyToken token, uint256 claimPlayerId) internal returns (uint256) {
        address owner = playerNFT.ownerOf(claimPlayerId);
        vm.prank(owner);
        return token.claim(claimPlayerId);
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

    /// @notice Compute the actual work of a registered vanity address.
    /// @param player Player committed in CurrencyToken initCode
    /// @param dayNumber Day committed in CurrencyToken initCode
    /// @param targetWork Target work committed in CurrencyToken initCode
    /// @param counter Counter committed in CurrencyToken initCode
    /// @param salt CREATE2 salt
    /// @return Expected work of the CREATE2 hash
    function _vanityWork(address player, uint256 dayNumber, uint256 targetWork, uint256 counter, bytes32 salt)
        internal
        view
        returns (uint256)
    {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetWork, counter, dayHash);
        bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), address(pool), salt, initCodeHash));
        return pool.addressToWork(address(uint160(uint256(create2Hash))));
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
        CurrencyToken token =
            new CurrencyToken(uint256(uint160(player1)), 0, pool.MIN_SHARE_WORK(), 0, bytes32(uint256(123)));

        vm.expectRevert(CurrencyToken.DistributionNotInitialized.selector);
        token.claim(uint256(uint160(player1)));
    }

    function testRevert_deployCurrency_beforeSnapshotDayPasses() public {
        address vanity = _registerCurrency(player1, 0, bytes32(uint256(502)), 0, pool.MIN_SHARE_WORK());

        vm.prank(player1);
        vm.expectRevert(abi.encodeWithSelector(MiningPool.DistributionSnapshotNotFrozen.selector, 0, 0));
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);
    }

    function testRevert_deployCurrency_zeroTotalSupply() public {
        address vanity = _registerCurrency(player1, 0, bytes32(uint256(503)), 0, pool.MIN_SHARE_WORK());

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
        uint256 claimed = _claim(token, playerId);

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
        uint256 claimed = _claim(token, playerId);

        assertEq(claimed, expected);
        assertEq(token.balanceOf(player2), expected);
    }

    function test_claim_mintsToCurrentPlayerNFTOwner() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player2));

        vm.prank(player2);
        playerNFT.transferFrom(player2, player3, playerId);

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(506)));
        uint256 claimed = _claim(token, playerId);

        assertEq(token.balanceOf(player2), 0);
        assertEq(token.balanceOf(player3), claimed);
    }

    function testRevert_claim_cannotClaimTwice() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player1));

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(507)));
        _claim(token, playerId);

        // Second claim reverts on the already-claimed flag, before the owner guard,
        // so the caller identity does not matter here.
        vm.expectRevert(abi.encodeWithSelector(CurrencyToken.AlreadyClaimed.selector, playerId));
        token.claim(playerId);
    }

    function testRevert_claim_callerNotOwner() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player1));
        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(516)));

        // player3 does not own player1's PlayerNFT, so it cannot claim that allocation.
        vm.expectRevert(CurrencyToken.CallerNotOwner.selector);
        vm.prank(player3);
        token.claim(playerId);
    }

    function testRevert_claim_zeroScoreNonDiscovererGetsNothing() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player3));
        _registerCurrency(player3, 0, bytes32(uint256(900)), 0, pool.MIN_SHARE_WORK());

        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(508)));

        // player3 owns its PlayerNFT (lazy-minted on registration), so it passes the
        // owner guard but then has nothing to claim on this day-1 discovery.
        vm.expectRevert(abi.encodeWithSelector(CurrencyToken.NothingToClaim.selector, playerId));
        vm.prank(player3);
        token.claim(playerId);
    }

    function test_claim_allPlayersDoesNotExceedDistributionSupply() public {
        _buildDay0Scores();
        (CurrencyToken token,) = _deployDay1Currency(bytes32(uint256(509)));

        _claim(token, uint256(uint160(player1)));
        _claim(token, uint256(uint160(player2)));

        assertLe(token.totalSupply(), DISTRIBUTION_SUPPLY);
    }

    function test_claim_scoresOnDiscoveryDayIgnored() public {
        _buildDay0Scores();
        uint256 playerId = uint256(uint160(player2));
        uint256 playerScore = pool.getPlayerScoreAt(playerId, 0);
        uint256 poolScore = pool.getPoolScoreAt(0);

        address vanity = _registerDay1Currency(bytes32(uint256(510)));
        _submitShare(player2, 1, 1, 3_000_000);

        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        uint256 expected = DISTRIBUTION_SUPPLY * 99 * playerScore / (100 * poolScore);
        uint256 claimed = _claim(token, playerId);

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
        _submitShare(player2, 2, 1, 4_000_000);

        uint256 expected = DISTRIBUTION_SUPPLY * 99 * playerScore / (100 * poolScore);
        uint256 claimed = _claim(token, playerId);

        assertEq(token.snapshotDay(), 0);
        assertEq(claimed, expected, "post-discovery score must not affect distribution");
    }

    function test_claim_usesFullPrecisionMulDivForLargeValues() public {
        _submitDay0Share(player1, 1);
        uint256 playerId = uint256(uint160(player1));
        uint256 hugeSupply = type(uint256).max / 99;
        mockPlayerScore = 1 << 200;
        mockPoolScore = mockPlayerScore;

        CurrencyToken token = new CurrencyToken(playerId, 0, pool.MIN_SHARE_WORK(), 0, pool.dayHashes(0));
        token.initializeDistribution(hugeSupply);

        uint256 expectedProportional = hugeSupply * 99 / 100;
        uint256 expectedBonus = hugeSupply / 100;
        uint256 claimed = _claim(token, playerId);

        assertEq(claimed, expectedProportional + expectedBonus);
        assertEq(token.balanceOf(player1), claimed);
    }

    function testRevert_claim_assertsPlayerScoreNotAbovePoolScore() public {
        _submitDay0Share(player1, 1);
        uint256 playerId = uint256(uint160(player1));
        mockPlayerScore = 2_000;
        mockPoolScore = 1_000;

        CurrencyToken token = new CurrencyToken(playerId, 0, pool.MIN_SHARE_WORK(), 0, pool.dayHashes(0));
        token.initializeDistribution(DISTRIBUTION_SUPPLY);

        // player1 owns its PlayerNFT, so it clears the owner guard and reaches the
        // playerScore <= poolScore assertion that the mock deliberately violates.
        vm.expectRevert(stdError.assertionError);
        vm.prank(player1);
        token.claim(playerId);
    }

    // =========================================================================
    //                          INTEGRATION TESTS
    // =========================================================================

    function test_fullFlow_multiPlayerMultiDay() public {
        _submitShare(player1, 0, 1, 0);
        _submitShare(player2, 0, 1, 1_000_000);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        _submitShare(player1, 1, 1, 2_000_000);
        _submitShare(player2, 1, 1, 3_000_000);
        _submitShare(player3, 1, 1, 4_000_000);

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
        address vanity = _registerCurrency(player1, 200, bytes32(uint256(513)), 2, pool.MIN_SHARE_WORK());

        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        uint256 p1Expected = DISTRIBUTION_SUPPLY * 99 * p1Score / (100 * poolScore) + DISTRIBUTION_SUPPLY / 100;
        uint256 p2Expected = DISTRIBUTION_SUPPLY * 99 * p2Score / (100 * poolScore);
        uint256 p3Expected = DISTRIBUTION_SUPPLY * 99 * p3Score / (100 * poolScore);

        assertEq(_claim(token, p1Id), p1Expected);
        assertEq(_claim(token, p2Id), p2Expected);
        assertEq(_claim(token, p3Id), p3Expected);
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
        _submitShare(player3, 1, 1, 5_000_000);

        uint256 currencyTwoP2Score = pool.getPlayerScoreAt(p2Id, 1);
        uint256 currencyTwoP3Score = pool.getPlayerScoreAt(p3Id, 1);
        uint256 currencyTwoPoolScore = pool.getPoolScoreAt(1);

        vm.warp(pool.dayZeroTimestamp() + 2 days);
        pool.getCurrentDayHash();
        address vanityTwo = _registerCurrency(player2, 300, bytes32(uint256(515)), 2, pool.MIN_SHARE_WORK());

        vm.prank(player2);
        CurrencyToken tokenTwo = pool.deployCurrency(vanityTwo, SECOND_DISTRIBUTION_SUPPLY);

        uint256 tokenOneP2Expected = DISTRIBUTION_SUPPLY * 99 * currencyOneP2Score / (100 * currencyOnePoolScore);
        uint256 tokenTwoP2Expected = SECOND_DISTRIBUTION_SUPPLY * 99 * currencyTwoP2Score / (100 * currencyTwoPoolScore)
            + SECOND_DISTRIBUTION_SUPPLY / 100;
        uint256 tokenTwoP3Expected = SECOND_DISTRIBUTION_SUPPLY * 99 * currencyTwoP3Score / (100 * currencyTwoPoolScore);

        assertEq(_claim(tokenOne, p2Id), tokenOneP2Expected);
        assertEq(tokenOne.balanceOf(player2), tokenOneP2Expected);

        assertEq(_claim(tokenTwo, p2Id), tokenTwoP2Expected);
        assertEq(_claim(tokenTwo, p3Id), tokenTwoP3Expected);
        assertEq(tokenTwo.balanceOf(player2), tokenTwoP2Expected);
        assertEq(tokenTwo.balanceOf(player3), tokenTwoP3Expected);

        // player3 owns its PlayerNFT, so it clears the owner guard but had no score on
        // currency one's day-0 snapshot, leaving nothing to claim there.
        vm.expectRevert(abi.encodeWithSelector(CurrencyToken.NothingToClaim.selector, p3Id));
        vm.prank(player3);
        tokenOne.claim(p3Id);
    }

    // =========================================================================
    //                          AUTO-BOOST TESTS
    // =========================================================================

    function test_deployCurrency_autoBoostsIntegratedWorkOnly() public {
        _buildDay0Scores();
        bytes32 salt = bytes32(uint256(516));
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        pool.getCurrentDayHash();
        uint256 vanityWork = _vanityWork(player1, 1, pool.MIN_SHARE_WORK(), 100, salt);

        uint256 workBefore = pool.totalIntegratedWork();
        uint256 shareCountBefore = pool.totalShareCount();
        uint256 poolScoreBefore = pool.getPoolScoreAt(0);

        address vanity = _registerCurrency(player1, 100, salt, 1, pool.MIN_SHARE_WORK());
        vm.prank(player1);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        assertEq(pool.totalIntegratedWork(), workBefore + vanityWork);
        assertEq(pool.totalShareCount(), shareCountBefore, "auto-boost must not add a share");
        assertEq(pool.getPoolScoreAt(0), poolScoreBefore, "auto-boost must not alter checkpoints");
    }
}
