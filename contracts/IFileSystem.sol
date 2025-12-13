// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFileSystem
 * @dev Interface for the FileSystem contract with VFAT-like structure
 * Data is packed into uint256 storage slots starting from slot 0
 * Entries are identified by storage slot numbers, accessed via Yul assembly
 */
interface IFileSystem {
    enum EntryType { FILE, DIRECTORY, LINK }
    
    // Packed entry metadata structure (stored in uint256 at specific storage slot)
    // Layout: entryType (1 bit) | timestamp (64 bits) | fileSize (30 bits)
    // Owner and group are stored in dedicated slots using keccak256 constants
    // Existence is determined by timestamp > 0
    struct EntryMetadata {
        EntryType entryType; // 1 bit (0=FILE, 1=DIRECTORY, 2=LINK)
        uint64 timestamp;    // 64 bits (0 means entry doesn't exist)
        uint32 fileSize;     // 30 bits (max ~1GB file)
    }
    
    struct Entry {
        EntryMetadata metadata;
        uint256 storageSlot; // The storage slot number for this entry
        bytes content;  // For compatibility - reconstructed from clusters
        address directoryTarget; // For directories: points to another IFileSystem contract
    }
    
    event FileCreated(address indexed owner, uint256 indexed storageSlot, uint256 timestamp, uint256 offset);
    event DirectoryCreated(address indexed owner, uint256 indexed storageSlot, address indexed target, uint256 timestamp);
    event FileUpdated(address indexed owner, uint256 indexed storageSlot, uint256 timestamp, uint256 offset);
    event EntryDeleted(address indexed owner, uint256 indexed storageSlot);
    
    /**
     * @dev Create a new file with optional offset (storage slot auto-assigned starting from 0)
     * @param name The name of the file
     * @param body The body/content of the file
     * @param offset The byte offset to start writing at (default 0)
     */
    function createFile(bytes memory name, bytes memory body, uint256 offset) external;
    
    /**
     * @dev Create a new directory pointing to another IFileSystem contract (storage slot auto-assigned starting from 0)
     * @param target The address of the IFileSystem contract this directory points to
     */
    function createDirectory(address target) external;
    
    /**
     * @dev Update file body at a specific offset
     * @param storageSlot The storage slot number of the file
     * @param body The new body/content of the file
     * @param offset The byte offset to start writing at (default 0)
     */
    function updateFile(uint256 storageSlot, bytes memory body, uint256 offset) external;
    
    /**
     * @dev Delete an entry (file or directory)
     * @param storageSlot The storage slot number of the entry
     */
    function deleteEntry(uint256 storageSlot) external;
    
    /**
     * @dev Get entry information at a specific storage slot
     * @param storageSlot The storage slot number
     * @return entryType The type of the entry (FILE or DIRECTORY)
     * @return owner The owner of the entry
     * @return name The name of the file (empty for directories)
     * @return body The body/content (for files, reconstructed from clusters)
     * @return timestamp The last modification timestamp
     * @return entryExists Whether the entry exists
     * @return fileSize The size of the file in bytes
     * @return directoryTarget For directories: the IFileSystem contract address this directory points to
     */
    function getEntry(uint256 storageSlot) 
        external 
        view 
        returns (
            EntryType entryType,
            address owner,
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        );
    
    /**
     * @dev Get all storage slots that have entries in this filesystem
     * @return An array of all storage slot numbers with entries
     */
    function getEntries() external view returns (uint256[] memory);
    
    /**
     * @dev Check if an entry exists at a specific storage slot
     * @param storageSlot The storage slot number
     * @return Whether the entry exists
     */
    function exists(uint256 storageSlot) external view returns (bool);
    
    /**
     * @dev Read file body at a specific offset
     * @param storageSlot The storage slot number of the file
     * @param offset The byte offset to start reading from
     * @param length The number of bytes to read (0 means read to end)
     * @return body The body bytes at the specified offset
     */
    function readFile(uint256 storageSlot, uint256 offset, uint256 length) 
        external 
        view 
        returns (bytes memory body);
    
    /**
     * @dev Write file body at a specific offset
     * @param storageSlot The storage slot number of the file
     * @param offset The byte offset to start writing at
     * @param body The body bytes to write
     */
    function writeFile(uint256 storageSlot, uint256 offset, bytes memory body) external;
    
    /**
     * @dev Read a specific cluster (32-byte chunk) from file storage
     * @param storageSlot The storage slot number of the file
     * @param clusterIndex The cluster index (0-based)
     * @return clusterData The 32-byte cluster data as uint256
     */
    function readCluster(uint256 storageSlot, uint256 clusterIndex) 
        external 
        view 
        returns (uint256 clusterData);
}

