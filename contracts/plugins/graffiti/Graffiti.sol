// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFileSystem} from "../../IFileSystem.sol";
import {IGraffitiBaseNFT} from "./IGraffitiBaseNFT.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/**
 * @title GraffitiPlugin
 * @dev Proxy contract that exposes IGraffitiBaseNFT collection as a filesystem
 * Each NFT appears as two files:
 * - {tokenId}.json - metadata file (without embedded image)
 * - {tokenId}.bmp - BMP image file
 * Storage slot mapping: tokenId * 2 = .json, tokenId * 2 + 1 = .bmp
 */
contract GraffitiPlugin is IFileSystem {
    using Strings for uint256;
    using Strings for address;

    IGraffitiBaseNFT public immutable graffitiContract;

    error NotImplemented();
    error InvalidStorageSlot();
    error TokenDoesNotExist();
    error InvalidChainId();

    constructor() {
        uint256 chainId = block.chainid;
        if (chainId == 8453) { // Base
            graffitiContract = IGraffitiBaseNFT(0xCc39Fe145eECe8a733833D7A78dCa7f287996693);
        } else if (chainId == 81457) { // Blast
            graffitiContract = IGraffitiBaseNFT(0x971b2d96eFc3cffb8bAcE89A17AbfEd0b8743cD1);
        } else if (chainId == 1301) { // Unichain
            graffitiContract = IGraffitiBaseNFT(0x971b2d96eFc3cffb8bAcE89A17AbfEd0b8743cD1);
        } else if (chainId == 59144) { // Linea
            graffitiContract = IGraffitiBaseNFT(0xE6d6AacC26201AFf57a666090f789b15591a8e44);
        } else {
            revert InvalidChainId();
        }
    }

    /**
     * @dev Parse storage slot to extract tokenId and file type
     * @return tokenId The NFT token ID
     * @return isJsonFile True if this is a .json file, false if .bmp
     */
    function _parseStorageSlot(uint256 storageSlot) private pure returns (uint256 tokenId, bool isJsonFile) {
        if (storageSlot % 2 == 0) {
            // Even slot = .json file
            tokenId = storageSlot / 2;
            isJsonFile = true;
        } else {
            // Odd slot = .bmp file
            tokenId = (storageSlot - 1) / 2;
            isJsonFile = false;
        }
    }

    /**
     * @dev Check if a token exists
     */
    function _tokenExists(uint256 tokenId) private view returns (bool) {
        if (tokenId >= graffitiContract.totalSupply()) {
            return false;
        }
        try graffitiContract.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev Get metadata JSON without embedded image
     */
    function _getMetadataJson(uint256 tokenId) private view returns (bytes memory) {
        if (!_tokenExists(tokenId)) {
            revert TokenDoesNotExist();
        }

        // Call getGraffitiBase which returns the struct
        // We'll extract the fields we need
        (uint256 id, uint32 color, address creator, address owner, address colorOwner, uint256[] memory graffiti) = 
            _getGraffitiBaseFields(tokenId);
        
        // Build description
        string memory desc = string(abi.encodePacked("Graffiti ", tokenId.toString()));
        if (tokenId % 2 == 0) {
            desc = string(abi.encodePacked(desc, unicode"º"));
        } else {
            desc = string(abi.encodePacked(desc, unicode"ª"));
        }
        desc = string(abi.encodePacked(desc, unicode" \\n\\n", " - Color: ", uint256(color).toHexString()));

        // Build RGB traits
        string memory rgbTraits = string(
            abi.encodePacked(
                _addIntTrait("Red", ((color & 0xFF0000) >> 16)),
                ", ",
                _addIntTrait("Green", ((color & 0x00FF00) >> 8)),
                ", ",
                _addIntTrait("Blue", ((color & 0x0000FF)))
            )
        );

        // Build JSON without image field
        return bytes(
            string(
                abi.encodePacked(
                    '{"name":"',
                    graffitiContract.name(),
                    '", "description":"',
                    desc,
                    '", "attributes": [',
                    rgbTraits,
                    "], ",
                    abi.encodePacked('"external_url": "https://6120.eu/posts/graffiti?gunit=', tokenId.toString()),
                    '"}'
                )
            )
        );
    }

    // Local struct matching GraffitiBase from IGraffitiBaseNFT
    struct LocalGraffitiBase {
        uint256 id;
        uint32 color;
        address creator;
        address owner;
        address colorOwner;
        uint256[] graffiti;
    }
    
    /**
     * @dev Extract fields from GraffitiBase struct
     * Define a local struct matching the return type of getGraffitiBase
     */
    function _getGraffitiBaseFields(uint256 tokenId) private view returns (
        uint256 id,
        uint32 color,
        address creator,
        address owner,
        address colorOwner,
        uint256[] memory graffiti
    ) {
        LocalGraffitiBase memory gb = _callGetGraffitiBase(tokenId);
        
        return (gb.id, gb.color, gb.creator, gb.owner, gb.colorOwner, gb.graffiti);
    }
    
    /**
     * @dev Call getGraffitiBase and return as local struct
     * Uses low-level call to get the struct data and decode it
     */
    function _callGetGraffitiBase(uint256 tokenId) private view returns (LocalGraffitiBase memory) {
        // Get the raw return data by using a low-level call
        (bool success, bytes memory data) = address(graffitiContract).staticcall(
            abi.encodeWithSignature("getGraffitiBase(uint256)", tokenId)
        );
        require(success, "Failed to call getGraffitiBase");
        
        // Decode the struct from the return data
        LocalGraffitiBase memory gb = abi.decode(data, (LocalGraffitiBase));
        
        return gb;
    }

    /**
     * @dev Helper to add integer trait
     */
    function _addIntTrait(string memory key, uint256 value) private pure returns (string memory) {
        return string(abi.encodePacked('{"', key, '": ', value.toString(), "}"));
    }

    /**
     * @dev Get file name for a storage slot
     */
    function _getFileName(uint256 storageSlot) private pure returns (bytes memory) {
        (uint256 tokenId, bool isJsonFile) = _parseStorageSlot(storageSlot);
        if (isJsonFile) {
            return bytes(string(abi.encodePacked(tokenId.toString(), ".json")));
        } else {
            return bytes(string(abi.encodePacked(tokenId.toString(), ".bmp")));
        }
    }

    /**
     * @dev Get file body for a storage slot
     */
    function _getFileBody(uint256 storageSlot) private view returns (bytes memory) {
        (uint256 tokenId, bool isJsonFile) = _parseStorageSlot(storageSlot);
        
        if (isJsonFile) {
            return _getMetadataJson(tokenId);
        } else {
            // For BMP files, return empty bytes if token doesn't exist (don't revert)
            if (!_tokenExists(tokenId)) {
                return new bytes(0);
            }
            return graffitiContract.BMP(tokenId);
        }
    }

    // ============ IFileSystem Implementation ============

    function createFile(bytes memory, bytes memory, uint256) external pure override {
        revert NotImplemented();
    }

    function createDirectory(bytes memory, address) external pure override {
        revert NotImplemented();
    }

    function updateFile(uint256, bytes memory, uint256) external pure override {
        revert NotImplemented();
    }

    function deleteEntry(uint256) external pure override {
        revert NotImplemented();
    }

    function writeFile(uint256, uint256, bytes memory) external pure override {
        revert NotImplemented();
    }

    function getEntry(uint256 storageSlot) 
        external 
        view 
        override
        returns (
            EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        )
    {
        (uint256 tokenId, ) = _parseStorageSlot(storageSlot);
        
        if (!_tokenExists(tokenId)) {
            entryExists = false;
            entryType = EntryType.FILE;
            owner = address(0);
            name = new bytes(0);
            body = new bytes(0);
            timestamp = 0;
            fileSize = 0;
            directoryTarget = address(0);
            return (entryType, owner, name, body, timestamp, entryExists, fileSize, directoryTarget);
        }

        entryExists = true;
        entryType = EntryType.FILE;
        owner = graffitiContract.ownerOf(tokenId);
        name = _getFileName(storageSlot);
        body = _getFileBody(storageSlot);
        timestamp = block.timestamp; // Use current timestamp as proxy
        fileSize = body.length;
        directoryTarget = address(0);
    }

    function getEntries() external view override returns (uint256[] memory) {
        uint256 totalSupply = graffitiContract.totalSupply();
        uint256[] memory entries = new uint256[](totalSupply * 2);
        uint256 index = 0;

        for (uint256 i = 0; i < totalSupply; i++) {
            // Add .json file slot
            entries[index] = i * 2;
            index++;
            // Add .bmp file slot
            entries[index] = i * 2 + 1;
            index++;
        }
        return entries;
    }

    function exists(uint256 storageSlot) external view override returns (bool) {
        (uint256 tokenId, ) = _parseStorageSlot(storageSlot);
        return _tokenExists(tokenId);
    }

    function readFile(uint256 storageSlot, uint256 offset, uint256 length) 
        external 
        view 
        override
        returns (bytes memory body)
    {
        bytes memory fullBody = _getFileBody(storageSlot);
        
        if (offset >= fullBody.length) {
            return new bytes(0);
        }

        uint256 end = length == 0 ? fullBody.length : offset + length;
        if (end > fullBody.length) {
            end = fullBody.length;
        }

        uint256 resultLength = end - offset;
        bytes memory result = new bytes(resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            result[i] = fullBody[offset + i];
        }
        
        return result;
    }

    function readCluster(uint256 storageSlot, uint256 clusterIndex) 
        external 
        view 
        override
        returns (uint256 clusterData)
    {
        bytes memory fullBody = _getFileBody(storageSlot);
        uint256 clusterOffset = clusterIndex * 32;
        
        if (clusterOffset >= fullBody.length) {
            return 0;
        }

        uint256 bytesToRead = 32;
        if (clusterOffset + bytesToRead > fullBody.length) {
            bytesToRead = fullBody.length - clusterOffset;
        }

        // Pack bytes into uint256 (big-endian: first byte at MSB)
        clusterData = 0;
        for (uint256 i = 0; i < bytesToRead && i < 32; i++) {
            clusterData |= uint256(uint8(fullBody[clusterOffset + i])) << (8 * (31 - i));
        }
        
        return clusterData;
    }
}