// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title PlayerNFT
/// @notice ERC-721 representing a player's identity in the mining pool.
///
/// TOKEN ID SCHEME:
///   tokenId = uint256(uint160(playerWalletAddress))
///   This means each wallet can only have ONE player identity.
///   The NFT is the on-chain proof that this wallet has participated.
///
/// LAZY MINTING:
///   Players don't explicitly register. The MiningPool automatically mints
///   a PlayerNFT on the player's first share submission. This keeps the UX
///   simple — just start mining, the NFT appears in your wallet.
///
/// TRANSFERABILITY:
///   PlayerNFTs are transferable. Transferring the NFT transfers ownership
///   of all accumulated mining credits. When currency tokens are distributed,
///   they go to whoever currently holds the PlayerNFT — making it a bearer
///   instrument for mining history.
///
///   Trading a PlayerNFT is like selling your "mining account" — the buyer
///   gets all future currency distributions proportional to the original
///   player's historical scores.
contract PlayerNFT is ERC721 {

    /// @notice The MiningPool contract that deploys and mints these NFTs.
    address public immutable miningPool;

    error OnlyMiningPool();

    /// @notice Deployed by MiningPool's constructor. msg.sender = MiningPool.
    constructor() ERC721("Vanity Player", "VPLAYER") {
        miningPool = msg.sender;
    }

    /// @notice Mint a PlayerNFT for a player if they don't have one yet.
    ///         Called by MiningPool on every share submission — idempotent.
    ///         If the player already has an NFT, this is a no-op.
    /// @param player The player's wallet address
    function mintIfNeeded(address player) external {
        if (msg.sender != miningPool) revert OnlyMiningPool();
        uint256 tokenId = uint256(uint160(player));
        // _ownerOf returns address(0) for non-existent tokens (doesn't revert)
        if (_ownerOf(tokenId) == address(0)) {
            _mint(player, tokenId);
        }
    }

    /// @notice Check if a player has been registered (has an NFT).
    /// @param player The player's wallet address
    /// @return True if the player has a PlayerNFT
    function isRegistered(address player) external view returns (bool) {
        return _ownerOf(uint256(uint160(player))) != address(0);
    }
}
