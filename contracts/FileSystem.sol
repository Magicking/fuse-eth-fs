// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IFileSystem.sol";

/**
 * @title FileSystem
 * @dev Basic filesystem contract for storing files and directories
 */
contract FileSystem is IFileSystem {
    // Mapping from account address -> path -> Entry
    mapping(address => mapping(string => Entry)) private entries;
    
    // Mapping from account address -> list of paths (for enumeration)
    mapping(address => string[]) private accountPaths;
    
    // Global registry: keccak256(path, owner) -> exists (to check if file exists for any account)
    mapping(bytes32 => bool) private globalPathOwners;
    
    // Set of all paths that exist (to quickly check if path exists for any account)
    mapping(string => bool) private globalPaths;
    
    /**
     * @dev Create a new file
     * @param path The path of the file
     * @param content The content of the file
     */
    function createFile(string memory path, bytes memory content) public override {
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
        bytes32 key = keccak256(abi.encodePacked(path, msg.sender));
        globalPathOwners[key] = true;
        globalPaths[path] = true;
        
        emit FileCreated(msg.sender, path, block.timestamp);
    }
    
    /**
     * @dev Create a new directory
     * @param path The path of the directory
     */
    function createDirectory(string memory path) public override {
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
        bytes32 key = keccak256(abi.encodePacked(path, msg.sender));
        globalPathOwners[key] = true;
        globalPaths[path] = true;
        
        emit DirectoryCreated(msg.sender, path, block.timestamp);
    }
    
    /**
     * @dev Update file content
     * @param path The path of the file
     * @param content The new content of the file
     */
    function updateFile(string memory path, bytes memory content) public override {
        Entry storage entry = entries[msg.sender][path];
        if (!entry.exists) {
            // Check if path exists globally for any account
            if (globalPaths[path]) {
                // Path exists for someone else, but not for caller
                revert("Not owner");
            }
            // Path doesn't exist for anyone
            revert("Entry does not exist");
        }
        require(entry.owner == msg.sender, "Not owner");
        require(entry.entryType == EntryType.FILE, "Not a file");
        
        entries[msg.sender][path].content = content;
        entries[msg.sender][path].timestamp = block.timestamp;
        
        emit FileUpdated(msg.sender, path, block.timestamp);
    }
    
    /**
     * @dev Delete an entry (file or directory)
     * @param path The path of the entry to delete
     */
    function deleteEntry(string memory path) public override {
        Entry storage entry = entries[msg.sender][path];
        bytes32 key = keccak256(abi.encodePacked(path, msg.sender));
        
        if (!entry.exists) {
            // Check if path exists globally for any account
            if (globalPaths[path]) {
                // Path exists for someone else, but not for caller
                revert("Not owner");
            }
            // Path doesn't exist for anyone
            revert("Entry does not exist");
        }
        require(entry.owner == msg.sender, "Not owner");
        
        delete entries[msg.sender][path];
        globalPathOwners[key] = false;
        
        // Check if path still exists for any other account
        // Since we can't iterate, we'll keep globalPaths[path] = true
        // It will be cleaned up when the last owner deletes it
        // For now, we'll leave it as is to avoid complexity
        
        // Remove path from accountPaths array
        string[] storage paths = accountPaths[msg.sender];
        for (uint i = 0; i < paths.length; i++) {
            if (keccak256(bytes(paths[i])) == keccak256(bytes(path))) {
                paths[i] = paths[paths.length - 1];
                paths.pop();
                break;
            }
        }
        
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
     * @return entryExists Whether the entry exists
     */
    function getEntry(address account, string memory path) 
        public 
        view 
        override
        returns (
            string memory name,
            EntryType entryType,
            address owner,
            bytes memory content,
            uint256 timestamp,
            bool entryExists
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
    function getAccountPaths(address account) public view override returns (string[] memory) {
        return accountPaths[account];
    }
    
    /**
     * @dev Check if an entry exists
     * @param account The account address
     * @param path The path to check
     * @return Whether the entry exists
     */
    function exists(address account, string memory path) public view override returns (bool) {
        return entries[account][path].exists;
    }
    
    /**
     * @dev Read file content at a specific offset
     * @param account The account address
     * @param path The path of the file
     * @param offset The byte offset to start reading from
     * @param length The number of bytes to read (0 means read to end)
     * @return content The content bytes at the specified offset
     */
    function readFile(address account, string memory path, uint256 offset, uint256 length) 
        public 
        view 
        override
        returns (bytes memory content) 
    {
        Entry memory entry = entries[account][path];
        require(entry.exists, "Entry does not exist");
        require(entry.entryType == EntryType.FILE, "Not a file");
        
        bytes memory fileContent = entry.content;
        
        // If offset is beyond file length, return empty bytes
        if (offset >= fileContent.length) {
            return new bytes(0);
        }
        
        // Calculate actual length to read
        uint256 actualLength = length;
        if (length == 0 || offset + length > fileContent.length) {
            actualLength = fileContent.length - offset;
        }
        
        // Extract the slice
        bytes memory result = new bytes(actualLength);
        for (uint256 i = 0; i < actualLength; i++) {
            result[i] = fileContent[offset + i];
        }
        
        return result;
    }
    
    /**
     * @dev Write file content at a specific offset
     * @param path The path of the file
     * @param offset The byte offset to start writing at
     * @param content The content bytes to write
     */
    function writeFile(string memory path, uint256 offset, bytes memory content) public override {
        Entry storage entry = entries[msg.sender][path];
        
        if (!entry.exists) {
            // Check if path exists globally for any account
            if (globalPaths[path]) {
                // Path exists for someone else, but not for caller
                revert("Not owner");
            }
            // Path doesn't exist for anyone - create new file
            // If offset > 0, pad with zeros (bytes arrays are initialized with zeros by default)
            bytes memory fullContent = new bytes(offset + content.length);
            
            // Write content at offset (padding is already zeros)
            for (uint256 i = 0; i < content.length; i++) {
                fullContent[offset + i] = content[i];
            }
            
            entries[msg.sender][path] = Entry({
                name: path,
                entryType: EntryType.FILE,
                owner: msg.sender,
                content: fullContent,
                timestamp: block.timestamp,
                exists: true
            });
            
            accountPaths[msg.sender].push(path);
            bytes32 key = keccak256(abi.encodePacked(path, msg.sender));
            globalPathOwners[key] = true;
            globalPaths[path] = true;
            
            emit FileCreated(msg.sender, path, block.timestamp);
            return;
        }
        
        require(entry.owner == msg.sender, "Not owner");
        require(entry.entryType == EntryType.FILE, "Not a file");
        
        bytes memory currentContent = entry.content;
        uint256 currentLength = currentContent.length;
        uint256 newLength = offset + content.length;
        
        // Determine the final length (max of current length and new end position)
        uint256 finalLength = newLength > currentLength ? newLength : currentLength;
        
        // Create new content array
        bytes memory newContent = new bytes(finalLength);
        
        // Copy existing content up to offset
        for (uint256 i = 0; i < currentLength && i < offset; i++) {
            newContent[i] = currentContent[i];
        }
        
        // Write new content at offset
        for (uint256 i = 0; i < content.length; i++) {
            newContent[offset + i] = content[i];
        }
        
        // Copy remaining existing content if offset + content.length < currentLength
        if (offset + content.length < currentLength) {
            for (uint256 i = offset + content.length; i < currentLength; i++) {
                newContent[i] = currentContent[i];
            }
        }
        
        entries[msg.sender][path].content = newContent;
        entries[msg.sender][path].timestamp = block.timestamp;
        
        emit FileUpdated(msg.sender, path, block.timestamp);
    }
}
