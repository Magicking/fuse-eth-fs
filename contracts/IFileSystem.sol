// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFileSystem
 * @dev Interface for the FileSystem contract
 */
interface IFileSystem {
    enum EntryType { FILE, DIRECTORY }
    
    struct Entry {
        string name;
        EntryType entryType;
        address owner;
        bytes content;  // For files, stores content; for directories, empty
        uint256 timestamp;
        bool exists;
    }
    
    event FileCreated(address indexed owner, string path, uint256 timestamp);
    event DirectoryCreated(address indexed owner, string path, uint256 timestamp);
    event FileUpdated(address indexed owner, string path, uint256 timestamp);
    event EntryDeleted(address indexed owner, string path);
    
    /**
     * @dev Create a new file
     * @param path The path of the file
     * @param content The content of the file
     */
    function createFile(string memory path, bytes memory content) external;
    
    /**
     * @dev Create a new directory
     * @param path The path of the directory
     */
    function createDirectory(string memory path) external;
    
    /**
     * @dev Update file content
     * @param path The path of the file
     * @param content The new content of the file
     */
    function updateFile(string memory path, bytes memory content) external;
    
    /**
     * @dev Delete an entry (file or directory)
     * @param path The path of the entry to delete
     */
    function deleteEntry(string memory path) external;
    
    /**
     * @dev Get entry information
     * @param account The account address
     * @param path The path of the entry
     * @return name The name of the entry
     * @return entryType The type of the entry (FILE or DIRECTORY)
     * @return owner The owner of the entry
     * @return content The content (for files)
     * @return timestamp The last modification timestamp
     * @return entryExists Whether the entry exists
     */
    function getEntry(address account, string memory path) 
        external 
        view 
        returns (
            string memory name,
            EntryType entryType,
            address owner,
            bytes memory content,
            uint256 timestamp,
            bool entryExists
        );
    
    /**
     * @dev Get all paths for an account
     * @param account The account address
     * @return An array of all paths owned by the account
     */
    function getAccountPaths(address account) external view returns (string[] memory);
    
    /**
     * @dev Check if an entry exists
     * @param account The account address
     * @param path The path to check
     * @return Whether the entry exists
     */
    function exists(address account, string memory path) external view returns (bool);
    
    /**
     * @dev Read file content at a specific offset
     * @param account The account address
     * @param path The path of the file
     * @param offset The byte offset to start reading from
     * @param length The number of bytes to read (0 means read to end)
     * @return content The content bytes at the specified offset
     */
    function readFile(address account, string memory path, uint256 offset, uint256 length) 
        external 
        view 
        returns (bytes memory content);
    
    /**
     * @dev Write file content at a specific offset
     * @param path The path of the file
     * @param offset The byte offset to start writing at
     * @param content The content bytes to write
     */
    function writeFile(string memory path, uint256 offset, bytes memory content) external;
}

