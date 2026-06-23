// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title CurrencyNFT
/// @notice ERC-721 representing a registered currency address, pre-deployment.
///
/// WHAT THIS REPRESENTS:
///   Every CREATE2 hash attempt produces an address that can become a currency.
///   If someone wants to turn that address into an ERC-20, they register it as a
///   CurrencyNFT. "Vanity" or "interesting" is intentionally subjective and not
///   enforced on-chain.
///
/// TOKEN ID SCHEME:
///   tokenId = uint256(uint160(vanityAddress))
///   Each currency address can only be registered once. The token ID IS the
///   address, making it trivially verifiable on OpenSea or any NFT viewer.
///
/// STORED DATA:
///   Each discovery stores the full set of CREATE2 parameters needed to
///   reproduce and deploy at the registered address:
///     - counter: the share submission index (part of initCode, affects address space)
///     - salt: the CREATE2 salt (the free search variable found off-chain)
///     - playerId: the registering player's identity
///     - dayNumber: day committed into the CREATE2 address (determines score snapshot)
///     - targetDifficulty: the difficulty target used during search
///
///   These params fully determine the currency address:
///     address = CREATE2(factory=MiningPool, salt=salt,
///               initCode=CurrencyToken(playerId, dayNumber, targetDifficulty, counter, dayHash))
///
/// LIFECYCLE:
///   1. Player chooses a hash result to treat as a currency address
///   2. Player calls MiningPool.registerCurrency() → CurrencyNFT minted
///   3. NFT holder calls MiningPool.deployCurrency() → CurrencyToken deployed
///   4. NFT becomes a souvenir / proof of provenance
///
/// TRANSFERABILITY:
///   CurrencyNFTs are freely tradeable. Transferring the NFT transfers the right
///   to deploy at the registered address and receive the 1% discoverer reward.
///   This is mostly because for example Etherscan needs some non-trivial communication
///   to fill token details etc. with the actual deplyoing wallet address.
///   So if something "worthy" is registered, someone more
///   expericenced could "buy" it, deploy and take care of it as the "owner" of the ERC20 token.
contract CurrencyNFT is ERC721 {

    /// @notice All parameters needed to reconstruct and deploy at the currency address.
    struct CurrencyDiscovery {
        uint256 counter;          // share index (in initCode, defines address space)
        bytes32 salt;             // CREATE2 salt (the free search variable)
        uint256 playerId;         // registering player's ID
        uint256 dayNumber;        // day committed into the address (score snapshot anchor)
        uint256 targetDifficulty; // difficulty target used during search
        bytes32 dayHash;          // on-chain daily randomness (prevents pre-computation)
        bool deployed;            // true after CurrencyToken has been deployed
    }

    /// @notice The MiningPool contract — only it can mint and mark as deployed.
    address public immutable miningPool;

    /// @notice Discovery data for each registered currency address.
    mapping(uint256 tokenId => CurrencyDiscovery) internal _discoveries;

    error OnlyMiningPool();
    error AlreadyRegistered();

    /// @notice Deployed by MiningPool's constructor. msg.sender = MiningPool.
    constructor() ERC721("Vanity Currency Discovery", "VCURRENCY") {
        miningPool = msg.sender;
    }

    /// @notice Register a new currency discovery. Called by MiningPool.
    /// @param to The registering player's address (receives the NFT)
    /// @param tokenId uint256(uint160(vanityAddress))
    /// @param counter The share index (part of initCode)
    /// @param salt The CREATE2 salt (the found search variable)
    /// @param playerId The registering player's ID
    /// @param dayNumber The day committed into the CREATE2 address
    /// @param targetDifficulty The difficulty target used
    /// @param dayHash The on-chain daily randomness for the discovery day
    function mint(
        address to,
        uint256 tokenId,
        uint256 counter,
        bytes32 salt,
        uint256 playerId,
        uint256 dayNumber,
        uint256 targetDifficulty,
        bytes32 dayHash
    ) external {
        if (msg.sender != miningPool) revert OnlyMiningPool();

        _discoveries[tokenId] = CurrencyDiscovery({
            counter: counter,
            salt: salt,
            playerId: playerId,
            dayNumber: dayNumber,
            targetDifficulty: targetDifficulty,
            dayHash: dayHash,
            deployed: false
        });

        _mint(to, tokenId);
    }

    /// @notice Mark a currency as deployed. Called by MiningPool after CREATE2 deployment.
    /// @param tokenId The currency's token ID (= registered address)
    function markDeployed(uint256 tokenId) external {
        if (msg.sender != miningPool) revert OnlyMiningPool();
        _discoveries[tokenId].deployed = true;
    }

    /// @notice Get the discovery data for a registered currency.
    /// @param tokenId The currency's token ID
    /// @return The CurrencyDiscovery struct with all stored parameters
    function getDiscovery(uint256 tokenId) external view returns (CurrencyDiscovery memory) {
        return _discoveries[tokenId];
    }

    /// @notice Check if a currency address has been registered.
    /// @param vanityAddress The address to check
    /// @return True if registered as a CurrencyNFT
    function isRegistered(address vanityAddress) external view returns (bool) {
        return _ownerOf(uint256(uint160(vanityAddress))) != address(0);
    }
}
