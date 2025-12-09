// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title FileSystem
 * @dev Basic filesystem contract for storing files and directories
 */
contract FileSystem {
    enum EntryType { FILE, DIRECTORY }
    
    struct Entry {
        string name;
        EntryType entryType;
        address owner;
        bytes content;  // For files, stores content; for directories, empty
        uint256 timestamp;
        bool exists;
    }
    
    // Mapping from account address -> path -> Entry
    mapping(address => mapping(string => Entry)) private entries;
    
    // Mapping from account address -> list of paths (for enumeration)
    mapping(address => string[]) private accountPaths;
    
    event FileCreated(address indexed owner, string path, uint256 timestamp);
    event DirectoryCreated(address indexed owner, string path, uint256 timestamp);
    event FileUpdated(address indexed owner, string path, uint256 timestamp);
    event EntryDeleted(address indexed owner, string path);
    
    /**
     * @dev Create a new file
     * @param path The path of the file
     * @param content The content of the file
     */
    function createFile(string memory path, bytes memory content) public {
        require(!entries[msg.sender][path].exists, "Entry already exists");
        
        entries[msg.sender][path] = Entry({
            name: path,
            entryType: EntryType.FILE,
            owner: msg.sender,
            content: content,
            timestamp: block.timestamp,
            exists: true
        });
        
        accountPaths[msg.sender].push(path);
        
        emit FileCreated(msg.sender, path, block.timestamp);
    }
    
    /**
     * @dev Create a new directory
     * @param path The path of the directory
     */
    function createDirectory(string memory path) public {
        require(!entries[msg.sender][path].exists, "Entry already exists");
        
        entries[msg.sender][path] = Entry({
            name: path,
            entryType: EntryType.DIRECTORY,
            owner: msg.sender,
            content: new bytes(0),
            timestamp: block.timestamp,
            exists: true
        });
        
        accountPaths[msg.sender].push(path);
        
        emit DirectoryCreated(msg.sender, path, block.timestamp);
    }
    
    /**
     * @dev Update file content
     * @param path The path of the file
     * @param content The new content of the file
     */
    function updateFile(string memory path, bytes memory content) public {
        require(entries[msg.sender][path].exists, "Entry does not exist");
        require(entries[msg.sender][path].entryType == EntryType.FILE, "Not a file");
        require(entries[msg.sender][path].owner == msg.sender, "Not owner");
        
        entries[msg.sender][path].content = content;
        entries[msg.sender][path].timestamp = block.timestamp;
        
        emit FileUpdated(msg.sender, path, block.timestamp);
    }
    
    /**
     * @dev Delete an entry (file or directory)
     * @param path The path of the entry to delete
     */
    function deleteEntry(string memory path) public {
        require(entries[msg.sender][path].exists, "Entry does not exist");
        require(entries[msg.sender][path].owner == msg.sender, "Not owner");
        
        delete entries[msg.sender][path];
        
        emit EntryDeleted(msg.sender, path);
    }
    
    /**
     * @dev Get entry information
     * @param account The account address
     * @param path The path of the entry
     * @return name The name of the entry
     * @return entryType The type of the entry (FILE or DIRECTORY)
     * @return owner The owner of the entry
     * @return content The content (for files)
     * @return timestamp The last modification timestamp
     * @return exists Whether the entry exists
     */
    function getEntry(address account, string memory path) 
        public 
        view 
        returns (
            string memory name,
            EntryType entryType,
            address owner,
            bytes memory content,
            uint256 timestamp,
            bool exists
        ) 
    {
        Entry memory entry = entries[account][path];
        return (
            entry.name,
            entry.entryType,
            entry.owner,
            entry.content,
            entry.timestamp,
            entry.exists
        );
    }
    
    /**
     * @dev Get all paths for an account
     * @param account The account address
     * @return An array of all paths owned by the account
     */
    function getAccountPaths(address account) public view returns (string[] memory) {
        return accountPaths[account];
    }
    
    /**
     * @dev Check if an entry exists
     * @param account The account address
     * @param path The path to check
     * @return Whether the entry exists
     */
    function exists(address account, string memory path) public view returns (bool) {
        return entries[account][path].exists;
    }
}
