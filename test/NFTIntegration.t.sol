// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {PlayerNFT} from "../src/PlayerNFT.sol";
import {CurrencyNFT} from "../src/CurrencyNFT.sol";
import {CurrencyToken} from "../src/CurrencyToken.sol";
import {LeadingZeros} from "../src/libraries/LeadingZeros.sol";

/// @title NFTIntegrationTest
/// @notice Tests for PlayerNFT lazy minting, CurrencyNFT registration,
///         and CurrencyToken deployment via CREATE2.
contract NFTIntegrationTest is Test {
    using LeadingZeros for bytes32;

    MiningPool public pool;
    PlayerNFT public playerNFT;
    CurrencyNFT public currencyNFT;

    address public player1;
    address public player2;

    function setUp() public {
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        pool = new MiningPool();
        playerNFT = pool.playerNFT();
        currencyNFT = pool.currencyNFT();
    }

    // =========================================================================
    //                         HELPER FUNCTIONS
    // =========================================================================

    function _findValidSalt(
        address player,
        uint256 dayNumber,
        uint256 targetDifficulty,
        uint256 counter,
        uint256 startSalt
    ) internal view returns (bytes32 salt, uint256 actualDifficulty) {
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetDifficulty, counter);
        address poolAddr = address(pool);
        uint256 minDiff = pool.MIN_SHARE_DIFFICULTY();

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
            assembly { mstore(0x40, freeMemPtr) }

            actualDifficulty = create2Hash.countLeadingZeroBits();
            if (actualDifficulty >= minDiff) {
                return (salt, actualDifficulty);
            }
        }
        revert("_findValidSalt: exhausted search space");
    }

    function _submitValidShare(
        address player,
        uint256 dayNumber,
        uint256 targetDifficulty,
        uint256 counter
    ) internal returns (bytes32 salt, uint256 actualDifficulty) {
        (salt, actualDifficulty) = _findValidSalt(
            player, dayNumber, targetDifficulty, counter, 0
        );
        vm.prank(player);
        pool.submitShare(targetDifficulty, dayNumber, counter, salt);
    }

    // =========================================================================
    //                      PLAYER NFT TESTS
    // =========================================================================

    function test_playerNFT_deployedByPool() public view {
        assertTrue(address(playerNFT) != address(0));
        assertEq(playerNFT.miningPool(), address(pool));
    }

    function test_playerNFT_notRegisteredBeforeSubmission() public view {
        assertFalse(playerNFT.isRegistered(player1));
    }

    function test_playerNFT_mintedOnFirstShare() public {
        _submitValidShare(player1, 0, 16, 0);

        assertTrue(playerNFT.isRegistered(player1));
        uint256 tokenId = uint256(uint160(player1));
        assertEq(playerNFT.ownerOf(tokenId), player1);
    }

    function test_playerNFT_idempotentOnSubsequentShares() public {
        _submitValidShare(player1, 0, 16, 0);
        _submitValidShare(player1, 0, 16, 1);

        uint256 tokenId = uint256(uint160(player1));
        assertEq(playerNFT.ownerOf(tokenId), player1);
        assertEq(playerNFT.balanceOf(player1), 1);
    }

    function test_playerNFT_twoPlayersGetSeparateNFTs() public {
        _submitValidShare(player1, 0, 16, 0);
        _submitValidShare(player2, 0, 16, 0);

        assertTrue(playerNFT.isRegistered(player1));
        assertTrue(playerNFT.isRegistered(player2));
        assertEq(playerNFT.balanceOf(player1), 1);
        assertEq(playerNFT.balanceOf(player2), 1);
    }

    function test_playerNFT_transferable() public {
        _submitValidShare(player1, 0, 16, 0);
        uint256 tokenId = uint256(uint160(player1));

        vm.prank(player1);
        playerNFT.transferFrom(player1, player2, tokenId);

        assertEq(playerNFT.ownerOf(tokenId), player2);
    }

    function testRevert_playerNFT_cannotMintDirectly() public {
        vm.prank(player1);
        vm.expectRevert(PlayerNFT.OnlyMiningPool.selector);
        playerNFT.mintIfNeeded(player1);
    }

    // =========================================================================
    //                    CURRENCY REGISTRATION TESTS
    // =========================================================================

    function test_registerCurrency_basic() public {
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, bytes32(uint256(12345)), 0, 16);

        assertTrue(currencyNFT.isRegistered(vanity));
        uint256 tokenId = uint256(uint160(vanity));
        assertEq(currencyNFT.ownerOf(tokenId), player1);
    }

    function test_registerCurrency_storesDiscoveryParams() public {
        uint256 counter = 7;
        bytes32 salt = bytes32(uint256(99999));
        uint256 dayNumber = 0;
        uint256 targetDifficulty = 20;

        vm.prank(player1);
        address vanity = pool.registerCurrency(counter, salt, dayNumber, targetDifficulty);

        uint256 tokenId = uint256(uint160(vanity));
        CurrencyNFT.CurrencyDiscovery memory disc = currencyNFT.getDiscovery(tokenId);

        assertEq(disc.counter, counter);
        assertEq(disc.salt, salt);
        assertEq(disc.playerId, uint256(uint160(player1)));
        assertEq(disc.dayNumber, dayNumber);
        assertEq(disc.targetDifficulty, targetDifficulty);
        assertFalse(disc.deployed);
    }

    function test_registerCurrency_matchesComputeVanityAddress() public {
        uint256 counter = 3;
        bytes32 salt = bytes32(uint256(42));

        address expected = pool.computeVanityAddress(player1, counter, salt, 0, 16);

        vm.prank(player1);
        address actual = pool.registerCurrency(counter, salt, 0, 16);

        assertEq(actual, expected, "Registered address should match computed address");
    }

    function test_registerCurrency_emitsEvent() public {
        uint256 playerId = uint256(uint160(player1));

        vm.expectEmit(true, false, false, false);
        emit MiningPool.CurrencyRegistered(playerId, address(0), 0, 0);

        vm.prank(player1);
        pool.registerCurrency(0, bytes32(uint256(100)), 0, 16);
    }

    function testRevert_registerCurrency_duplicateAddress() public {
        bytes32 salt = bytes32(uint256(100));
        vm.prank(player1);
        pool.registerCurrency(0, salt, 0, 16);

        // Same params → same address → should revert
        vm.prank(player1);
        vm.expectRevert(MiningPool.CurrencyAlreadyRegistered.selector);
        pool.registerCurrency(0, salt, 0, 16);
    }

    function testRevert_registerCurrency_invalidDay() public {
        vm.prank(player1);
        vm.expectRevert(MiningPool.InvalidDayNumber.selector);
        pool.registerCurrency(0, bytes32(uint256(100)), 5, 16);
    }

    function test_registerCurrency_nftTransferable() public {
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, bytes32(uint256(100)), 0, 16);
        uint256 tokenId = uint256(uint160(vanity));

        vm.prank(player1);
        currencyNFT.transferFrom(player1, player2, tokenId);

        assertEq(currencyNFT.ownerOf(tokenId), player2);
    }

    // =========================================================================
    //                    CURRENCY DEPLOYMENT TESTS
    // =========================================================================

    function test_deployCurrency_basic() public {
        bytes32 salt = bytes32(uint256(500));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);

        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity);

        assertEq(address(token), vanity);
        assertEq(token.playerId(), uint256(uint160(player1)));
        assertEq(token.dayNumber(), 0);
        assertEq(token.targetDifficulty(), 16);
        assertEq(token.counter(), 0);
        assertEq(token.miningPool(), address(pool));
    }

    function test_deployCurrency_markedAsDeployed() public {
        bytes32 salt = bytes32(uint256(500));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);

        vm.prank(player1);
        pool.deployCurrency(vanity);

        uint256 tokenId = uint256(uint160(vanity));
        CurrencyNFT.CurrencyDiscovery memory disc = currencyNFT.getDiscovery(tokenId);
        assertTrue(disc.deployed);
    }

    function test_deployCurrency_emitsEvent() public {
        bytes32 salt = bytes32(uint256(500));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);

        vm.expectEmit(true, false, false, false);
        emit MiningPool.CurrencyDeployed(vanity, address(0));

        vm.prank(player1);
        pool.deployCurrency(vanity);
    }

    function test_deployCurrency_byNftTransferRecipient() public {
        bytes32 salt = bytes32(uint256(500));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);
        uint256 tokenId = uint256(uint160(vanity));

        vm.prank(player1);
        currencyNFT.transferFrom(player1, player2, tokenId);

        vm.prank(player2);
        CurrencyToken token = pool.deployCurrency(vanity);

        assertEq(address(token), vanity);
    }

    function testRevert_deployCurrency_notOwner() public {
        bytes32 salt = bytes32(uint256(500));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);

        vm.prank(player2);
        vm.expectRevert(MiningPool.NotCurrencyOwner.selector);
        pool.deployCurrency(vanity);
    }

    function testRevert_deployCurrency_alreadyDeployed() public {
        bytes32 salt = bytes32(uint256(500));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);

        vm.prank(player1);
        pool.deployCurrency(vanity);

        vm.prank(player1);
        vm.expectRevert(MiningPool.CurrencyAlreadyDeployed.selector);
        pool.deployCurrency(vanity);
    }

    function testRevert_deployCurrency_notRegistered() public {
        vm.prank(player1);
        vm.expectRevert(MiningPool.CurrencyNotRegistered.selector);
        pool.deployCurrency(address(0x1234));
    }

    // =========================================================================
    //                    FULL FLOW: MINE → REGISTER → DEPLOY
    // =========================================================================

    function test_fullFlow_mineRegisterDeploy() public {
        // 1. Player submits shares (mines)
        _submitValidShare(player1, 0, 16, 0);
        assertTrue(playerNFT.isRegistered(player1), "Player should have NFT after mining");

        // 2. Player discovers and registers a vanity address
        bytes32 salt = bytes32(uint256(777));
        vm.prank(player1);
        address vanity = pool.registerCurrency(0, salt, 0, 16);
        assertTrue(currencyNFT.isRegistered(vanity), "Currency should be registered");

        // 3. Player deploys the CurrencyToken at the vanity address
        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity);

        // Verify the full chain
        assertEq(address(token), vanity, "Token deployed at vanity address");
        assertEq(token.miningPool(), address(pool), "Token knows its pool");
        assertTrue(
            pool.getPlayerScoreAt(uint256(uint160(player1)), 0) > 0,
            "Player has mining score"
        );
        assertTrue(vanity.code.length > 0, "Vanity address should have deployed code");
    }
}
