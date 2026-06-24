// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {MiningPool} from "../src/MiningPool.sol";
import {PlayerNFT} from "../src/PlayerNFT.sol";
import {CurrencyNFT} from "../src/CurrencyNFT.sol";
import {CurrencyToken} from "../src/CurrencyToken.sol";

/// @title NFTIntegrationTest
/// @notice Tests for PlayerNFT lazy minting, CurrencyNFT registration,
///         and CurrencyToken deployment via CREATE2.
contract NFTIntegrationTest is Test {
    MiningPool public pool;
    PlayerNFT public playerNFT;
    CurrencyNFT public currencyNFT;

    address public player1;
    address public player2;
    uint256 public constant DISTRIBUTION_SUPPLY = 1_000_000 ether;

    function setUp() public {
        player1 = makeAddr("player1");
        player2 = makeAddr("player2");
        pool = new MiningPool(block.chainid);
        playerNFT = pool.playerNFT();
        currencyNFT = pool.currencyNFT();
    }

    // =========================================================================
    //                         HELPER FUNCTIONS
    // =========================================================================

    function _findValidSalt(address player, uint256 dayNumber, uint256 targetWork, uint256 counter, uint256 startSalt)
        internal
        view
        returns (bytes32 salt, uint256 actualWork)
    {
        bytes32 dayHash = pool.dayHashes(dayNumber);
        bytes32 initCodeHash = pool.getInitCodeHash(player, dayNumber, targetWork, counter, dayHash);
        address poolAddr = address(pool);
        uint256 minWork = pool.MIN_SHARE_WORK();

        uint256 freeMemPtr;
        assembly { freeMemPtr := mload(0x40) }

        for (uint256 i = startSalt; i < startSalt + 10_000_000; i++) {
            salt = bytes32(i);
            bytes32 create2Hash = keccak256(abi.encodePacked(bytes1(0xff), poolAddr, salt, initCodeHash));
            assembly { mstore(0x40, freeMemPtr) }

            actualWork = pool.hashToWork(create2Hash);
            if (actualWork >= minWork) {
                return (salt, actualWork);
            }
        }
        revert("_findValidSalt: exhausted search space");
    }

    function _submitValidShare(address player, uint256 dayNumber, uint256 targetWork, uint256 counter)
        internal
        returns (bytes32 salt, uint256 actualWork)
    {
        (salt, actualWork) = _findValidSalt(player, dayNumber, targetWork, counter, 0);
        pool.submitShare(player, targetWork, dayNumber, counter, salt);
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
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);

        assertTrue(playerNFT.isRegistered(player1));
        uint256 tokenId = uint256(uint160(player1));
        assertEq(playerNFT.ownerOf(tokenId), player1);
    }

    function test_playerNFT_idempotentOnSubsequentShares() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 2);

        uint256 tokenId = uint256(uint160(player1));
        assertEq(playerNFT.ownerOf(tokenId), player1);
        assertEq(playerNFT.balanceOf(player1), 1);
    }

    function test_playerNFT_twoPlayersGetSeparateNFTs() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        _submitValidShare(player2, 0, pool.MIN_SHARE_WORK(), 1);

        assertTrue(playerNFT.isRegistered(player1));
        assertTrue(playerNFT.isRegistered(player2));
        assertEq(playerNFT.balanceOf(player1), 1);
        assertEq(playerNFT.balanceOf(player2), 1);
    }

    function test_playerNFT_transferable() public {
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
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
        address vanity = pool.registerCurrency(player1, 0, bytes32(uint256(12345)), 0, pool.MIN_SHARE_WORK());

        assertTrue(currencyNFT.isRegistered(vanity));
        uint256 tokenId = uint256(uint160(vanity));
        assertEq(currencyNFT.ownerOf(tokenId), player1);
    }

    function test_registerCurrency_storesDiscoveryParams() public {
        uint256 counter = 7;
        bytes32 salt = bytes32(uint256(99999));
        uint256 dayNumber = 0;
        uint256 targetWork = 1_000_000;

        address vanity = pool.registerCurrency(player1, counter, salt, dayNumber, targetWork);

        uint256 tokenId = uint256(uint160(vanity));
        CurrencyNFT.CurrencyDiscovery memory disc = currencyNFT.getDiscovery(tokenId);

        assertEq(disc.counter, counter);
        assertEq(disc.salt, salt);
        assertEq(disc.playerId, uint256(uint160(player1)));
        assertEq(disc.dayNumber, dayNumber);
        assertEq(disc.targetWork, targetWork);
        assertEq(disc.dayHash, pool.dayHashes(dayNumber), "dayHash should match pool's day hash");
        assertFalse(disc.deployed);
    }

    function test_registerCurrency_matchesComputeVanityAddress() public {
        uint256 counter = 3;
        bytes32 salt = bytes32(uint256(42));
        bytes32 dayHash = pool.dayHashes(0);

        address expected = pool.computeVanityAddress(player1, counter, salt, 0, pool.MIN_SHARE_WORK(), dayHash);

        address actual = pool.registerCurrency(player1, counter, salt, 0, pool.MIN_SHARE_WORK());

        assertEq(actual, expected, "Registered address should match computed address");
    }

    function test_registerCurrency_emitsEvent() public {
        uint256 playerId = uint256(uint160(player1));

        vm.expectEmit(true, false, false, false);
        emit MiningPool.CurrencyRegistered(playerId, address(0), 0, 0);

        pool.registerCurrency(player1, 0, bytes32(uint256(100)), 0, pool.MIN_SHARE_WORK());
    }

    function testRevert_registerCurrency_duplicateAddress() public {
        uint256 minWork = pool.MIN_SHARE_WORK();
        bytes32 salt = bytes32(uint256(100));
        pool.registerCurrency(player1, 0, salt, 0, minWork);

        // Same params → same address → should revert
        vm.expectRevert(MiningPool.CurrencyAlreadyRegistered.selector);
        pool.registerCurrency(player1, 0, salt, 0, minWork);
    }

    function testRevert_registerCurrency_invalidDay() public {
        uint256 minWork = pool.MIN_SHARE_WORK();
        vm.expectRevert(MiningPool.InvalidDayNumber.selector);
        pool.registerCurrency(player1, 0, bytes32(uint256(100)), 5, minWork);
    }

    function test_registerCurrency_thirdPartyRegistration() public {
        bytes32 salt = bytes32(uint256(42));

        // player2 registers a currency on behalf of player1 — NFT goes to player1
        vm.prank(player2);
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        uint256 tokenId = uint256(uint160(vanity));
        assertEq(currencyNFT.ownerOf(tokenId), player1, "NFT minted to PlayerNFT owner, not caller");
    }

    function test_registerCurrency_mintsToPlayerNFTOwner() public {
        // player1 submits a share (mints PlayerNFT)
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);

        // player1 transfers PlayerNFT to player2
        uint256 playerTokenId = uint256(uint160(player1));
        vm.prank(player1);
        playerNFT.transferFrom(player1, player2, playerTokenId);

        // Register a currency for player1's address — should go to player2 (current NFT owner)
        bytes32 salt = bytes32(uint256(42));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        uint256 currencyTokenId = uint256(uint160(vanity));
        assertEq(currencyNFT.ownerOf(currencyTokenId), player2, "CurrencyNFT goes to current PlayerNFT owner");
    }

    function test_registerCurrency_lazyMintsPlayerNFT() public {
        // player1 has never submitted a share — no PlayerNFT yet
        assertFalse(playerNFT.isRegistered(player1));

        address vanity = pool.registerCurrency(player1, 0, bytes32(uint256(42)), 0, pool.MIN_SHARE_WORK());

        // PlayerNFT should have been lazy-minted
        assertTrue(playerNFT.isRegistered(player1));
        // CurrencyNFT should go to player1 (the freshly-minted PlayerNFT owner)
        uint256 tokenId = uint256(uint160(vanity));
        assertEq(currencyNFT.ownerOf(tokenId), player1);
    }

    function test_registerCurrency_nftTransferable() public {
        address vanity = pool.registerCurrency(player1, 0, bytes32(uint256(100)), 0, pool.MIN_SHARE_WORK());
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
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        assertEq(address(token), vanity);
        assertEq(token.playerId(), uint256(uint160(player1)));
        assertEq(token.dayNumber(), 0);
        assertEq(token.targetWork(), pool.MIN_SHARE_WORK());
        assertEq(token.counter(), 0);
        assertEq(token.dayHash(), pool.dayHashes(0), "Deployed token should store the day hash");
        assertEq(token.miningPool(), address(pool));
        assertEq(token.distributionSupply(), DISTRIBUTION_SUPPLY);
        assertEq(token.snapshotDay(), 0);
        assertTrue(token.initialized(), "Distribution should be initialized during deployment");
    }

    function test_deployCurrency_markedAsDeployed() public {
        bytes32 salt = bytes32(uint256(500));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player1);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        uint256 tokenId = uint256(uint160(vanity));
        CurrencyNFT.CurrencyDiscovery memory disc = currencyNFT.getDiscovery(tokenId);
        assertTrue(disc.deployed);
    }

    function test_deployCurrency_emitsEvent() public {
        bytes32 salt = bytes32(uint256(500));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        vm.expectEmit(true, false, false, false);
        emit MiningPool.CurrencyDeployed(vanity, address(0), 0, 0);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player1);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);
    }

    function test_deployCurrency_byNftTransferRecipient() public {
        bytes32 salt = bytes32(uint256(500));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());
        uint256 tokenId = uint256(uint160(vanity));

        vm.prank(player1);
        currencyNFT.transferFrom(player1, player2, tokenId);

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player2);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        assertEq(address(token), vanity);
    }

    function testRevert_deployCurrency_notOwner() public {
        bytes32 salt = bytes32(uint256(500));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player2);
        vm.expectRevert(MiningPool.NotCurrencyOwner.selector);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);
    }

    function testRevert_deployCurrency_alreadyDeployed() public {
        bytes32 salt = bytes32(uint256(500));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());

        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player1);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        vm.prank(player1);
        vm.expectRevert(MiningPool.CurrencyAlreadyDeployed.selector);
        pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);
    }

    function testRevert_deployCurrency_notRegistered() public {
        vm.prank(player1);
        vm.expectRevert(MiningPool.CurrencyNotRegistered.selector);
        pool.deployCurrency(address(0x1234), DISTRIBUTION_SUPPLY);
    }

    // =========================================================================
    //                    FULL FLOW: MINE → REGISTER → DEPLOY
    // =========================================================================

    function test_fullFlow_mineRegisterDeploy() public {
        // 1. Player submits shares (mines)
        _submitValidShare(player1, 0, pool.MIN_SHARE_WORK(), 1);
        assertTrue(playerNFT.isRegistered(player1), "Player should have NFT after mining");

        // 2. Player discovers and registers a vanity address
        bytes32 salt = bytes32(uint256(777));
        address vanity = pool.registerCurrency(player1, 0, salt, 0, pool.MIN_SHARE_WORK());
        assertTrue(currencyNFT.isRegistered(vanity), "Currency should be registered");

        // 3. Player deploys the CurrencyToken at the vanity address
        vm.warp(pool.dayZeroTimestamp() + 1 days);
        vm.prank(player1);
        CurrencyToken token = pool.deployCurrency(vanity, DISTRIBUTION_SUPPLY);

        // Verify the full chain
        assertEq(address(token), vanity, "Token deployed at vanity address");
        assertEq(token.miningPool(), address(pool), "Token knows its pool");
        assertTrue(pool.getPlayerScoreAt(uint256(uint160(player1)), 0) > 0, "Player has mining score");
        assertTrue(vanity.code.length > 0, "Vanity address should have deployed code");
    }
}
