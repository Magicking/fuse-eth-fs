// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IGraffitiBaseNFT
 * @dev Interface for GraffitiBaseNFT contract
 */
interface IGraffitiBaseNFT {
    struct GraffitiBase {
        uint256 id;
        uint32 color;
        address creator;
        address owner;
        address colorOwner;
        uint256[] graffiti;
    }

    /**
     * @dev Returns the total supply of tokens
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the owner of a token
     * @param tokenId The token ID
     */
    function ownerOf(uint256 tokenId) external view returns (address);

    /**
     * @dev Returns the name of the NFT collection
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the GraffitiBase struct for a given token ID
     * @param tokenId The token ID
     */
    function getGraffitiBase(uint256 tokenId) external view returns (GraffitiBase memory);

    /**
     * @dev Returns the BMP image data for a given token ID
     * @param tokenId The token ID
     */
    function BMP(uint256 tokenId) external view returns (bytes memory);
}

