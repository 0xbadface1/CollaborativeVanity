// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @title CurrencyNFT
/// @notice ERC-721 representing a discovered vanity address, pre-deployment.
///
/// WHAT THIS REPRESENTS:
///   When a player finds a CREATE2 salt that produces an "interesting" address
///   (e.g. 0xBadFace..., 0xDeadBeef...), they register it as a CurrencyNFT.
///   The NFT proves discovery and grants the right to deploy a CurrencyToken
///   at that vanity address.
///
/// TOKEN ID SCHEME:
///   tokenId = uint256(uint160(vanityAddress))
///   Each vanity address can only be registered once. The token ID IS the
///   address, making it trivially verifiable on OpenSea or any NFT viewer.
///
/// STORED DATA:
///   Each discovery stores the full set of CREATE2 parameters needed to
///   reproduce and deploy at the vanity address:
///     - counter: the share submission index (part of initCode, affects address space)
///     - salt: the CREATE2 salt (the free search variable found off-chain)
///     - playerId: the discoverer's identity
///     - dayNumber: which day this was discovered (determines score snapshot)
///     - targetDifficulty: the difficulty target used during search
///
///   These params fully determine the vanity address:
///     address = CREATE2(factory=MiningPool, salt=salt,
///               initCode=CurrencyToken(playerId, dayNumber, targetDifficulty, counter, dayHash))
///
/// LIFECYCLE:
///   1. Player discovers vanity address (off-chain search)
///   2. Player calls MiningPool.registerCurrency() → CurrencyNFT minted
///   3. NFT holder calls MiningPool.deployCurrency() → CurrencyToken deployed
///   4. NFT becomes a souvenir / proof of provenance
///
/// TRANSFERABILITY:
///   CurrencyNFTs are freely tradeable. Selling the NFT transfers the right
///   to deploy at the vanity address and receive the 1% discoverer reward.
///   This creates a market for vanity addresses before they're even deployed.
contract CurrencyNFT is ERC721 {

    /// @notice All parameters needed to reconstruct and deploy at the vanity address.
    struct CurrencyDiscovery {
        uint256 counter;          // share index (in initCode, defines address space)
        bytes32 salt;             // CREATE2 salt (the free search variable)
        uint256 playerId;         // discoverer's player ID
        uint256 dayNumber;        // day of discovery (score snapshot anchor)
        uint256 targetDifficulty; // difficulty target used during search
        bytes32 dayHash;          // on-chain daily randomness (prevents pre-computation)
        bool deployed;            // true after CurrencyToken has been deployed
    }

    /// @notice The MiningPool contract — only it can mint and mark as deployed.
    address public immutable miningPool;

    /// @notice Discovery data for each registered vanity address.
    mapping(uint256 tokenId => CurrencyDiscovery) internal _discoveries;

    error OnlyMiningPool();
    error AlreadyRegistered();

    /// @notice Deployed by MiningPool's constructor. msg.sender = MiningPool.
    constructor() ERC721("Vanity Currency Discovery", "VCURRENCY") {
        miningPool = msg.sender;
    }

    /// @notice Register a new currency discovery. Called by MiningPool.
    /// @param to The discoverer's address (receives the NFT)
    /// @param tokenId uint256(uint160(vanityAddress))
    /// @param counter The share index (part of initCode)
    /// @param salt The CREATE2 salt (the found search variable)
    /// @param playerId The discoverer's player ID
    /// @param dayNumber The day of discovery
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
    /// @param tokenId The currency's token ID (= vanity address)
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

    /// @notice Check if a vanity address has been registered.
    /// @param vanityAddress The address to check
    /// @return True if registered as a CurrencyNFT
    function isRegistered(address vanityAddress) external view returns (bool) {
        return _ownerOf(uint256(uint160(vanityAddress))) != address(0);
    }
}
