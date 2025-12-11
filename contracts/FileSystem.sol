// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IFileSystem.sol";

/**
 * @title FileSystem
 * @dev VFAT-like filesystem contract with packed storage accessed via Yul assembly
 * Data is stored in clusters (32-byte chunks) at specific storage slots
 * Entry metadata is packed into uint256 values for efficiency
 * All storage access uses Yul assembly (sload/sstore) for direct slot manipulation
 */
contract FileSystem is IFileSystem {
    // Storage layout:
    // - Entry metadata: stored at storageSlot (packed uint256)
    // - Directory target: stored at storageSlot + 1 (if directory)
    // - File clusters: stored at storageSlot + 2 + clusterIndex
    // - Entry enumeration: mapping to track which slots are used
    
    // Base storage slot for entry metadata mapping
    // mapping(uint256 => uint256) entryMetadata; // slot 0
    // mapping(uint256 => address) directoryTargets; // slot 1
    // mapping(uint256 => mapping(uint256 => uint256)) fileClusters; // slot 2
    // uint256[] entrySlots; // slot 3
    
    // Constants for packing/unpacking metadata
    // Layout: owner (160 bits, bits 96-255) | entryType (1 bit, bit 95) | exists (1 bit, bit 94) | timestamp (64 bits, bits 30-93) | fileSize (30 bits, bits 0-29)
    uint256 private constant MASK_OWNER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF000000000000000000000000;
    uint256 private constant MASK_ENTRY_TYPE = 0x0000000000000000000000000000000000000000800000000000000000000000;
    uint256 private constant MASK_EXISTS = 0x0000000000000000000000000000000000000000400000000000000000000000;
    uint256 private constant MASK_TIMESTAMP = 0x00000000000000000000000000000000000000003FFFFFFFFFFFFFFFC0000000;
    uint256 private constant MASK_FILE_SIZE = 0x000000000000000000000000000000000000000000000000000000003FFFFFFF;
    
    // Storage slot offsets
    uint256 private constant SLOT_ENTRY_METADATA = 0;
    uint256 private constant SLOT_DIRECTORY_TARGETS = 1;
    uint256 private constant SLOT_FILE_CLUSTERS = 2;
    uint256 private constant SLOT_ENTRY_SLOTS = 3;
    
    /**
     * @dev Get storage slot for entry metadata
     */
    function _getMetadataSlot(uint256 storageSlot) private pure returns (uint256) {
        // mapping(uint256 => uint256) entryMetadata; // slot 0
        // slot = keccak256(abi.encodePacked(storageSlot, SLOT_ENTRY_METADATA))
        return uint256(keccak256(abi.encodePacked(storageSlot, SLOT_ENTRY_METADATA)));
    }
    
    /**
     * @dev Get storage slot for directory target
     */
    function _getDirectoryTargetSlot(uint256 storageSlot) private pure returns (uint256) {
        // mapping(uint256 => address) directoryTargets; // slot 1
        return uint256(keccak256(abi.encodePacked(storageSlot, SLOT_DIRECTORY_TARGETS)));
    }
    
    /**
     * @dev Get storage slot for file cluster
     */
    function _getClusterSlot(uint256 storageSlot, uint256 clusterIndex) private pure returns (uint256) {
        // mapping(uint256 => mapping(uint256 => uint256)) fileClusters; // slot 2
        // First mapping: keccak256(abi.encodePacked(storageSlot, SLOT_FILE_CLUSTERS))
        uint256 firstMappingSlot = uint256(keccak256(abi.encodePacked(storageSlot, SLOT_FILE_CLUSTERS)));
        // Second mapping: keccak256(abi.encodePacked(clusterIndex, firstMappingSlot))
        return uint256(keccak256(abi.encodePacked(clusterIndex, firstMappingSlot)));
    }
    
    /**
     * @dev Load value from storage slot using Yul
     */
    function _sload(uint256 slot) private view returns (uint256 value) {
        assembly {
            value := sload(slot)
        }
    }
    
    /**
     * @dev Store value to storage slot using Yul
     */
    function _sstore(uint256 slot, uint256 value) private {
        assembly {
            sstore(slot, value)
        }
    }
    
    /**
     * @dev Pack entry metadata into uint256
     * Layout: owner (160 bits) | entryType (1 bit) | exists (1 bit) | timestamp (64 bits) | fileSize (30 bits)
     */
    function _packMetadata(
        address owner,
        EntryType entryType,
        bool existsFlag,
        uint64 timestamp,
        uint32 fileSize
    ) private pure returns (uint256) {
        uint256 packed = 0;
        // Owner: bits 96-255 (160 bits)
        packed |= uint256(uint160(owner)) << 96;
        // EntryType: bit 95
        if (entryType == EntryType.DIRECTORY) {
            packed |= uint256(1) << 95;
        }
        // Exists: bit 94
        if (existsFlag) {
            packed |= uint256(1) << 94;
        }
        // Timestamp: bits 30-93 (64 bits)
        packed |= uint256(timestamp) << 30;
        // FileSize: bits 0-29 (30 bits, max ~1GB)
        packed |= uint256(fileSize) & 0x3FFFFFFF;
        return packed;
    }
    
    /**
     * @dev Unpack entry metadata from uint256
     */
    function _unpackMetadata(uint256 packed) private pure returns (
        address owner,
        EntryType entryType,
        bool existsFlag,
        uint64 timestamp,
        uint32 fileSize
    ) {
        // Owner: bits 96-255
        owner = address(uint160(packed >> 96));
        // EntryType: bit 95
        entryType = (packed & MASK_ENTRY_TYPE) != 0 ? EntryType.DIRECTORY : EntryType.FILE;
        // Exists: bit 94
        existsFlag = (packed & MASK_EXISTS) != 0;
        // Timestamp: bits 30-93
        timestamp = uint64((packed & MASK_TIMESTAMP) >> 30);
        // FileSize: bits 0-29
        fileSize = uint32(packed & MASK_FILE_SIZE);
    }
    
    /**
     * @dev Get cluster index from byte offset
     */
    function _getClusterIndex(uint256 byteOffset) private pure returns (uint256) {
        return byteOffset / 32;
    }
    
    /**
     * @dev Get byte offset within cluster
     */
    function _getClusterOffset(uint256 byteOffset) private pure returns (uint256) {
        return byteOffset % 32;
    }
    
    /**
     * @dev Write bytes to clusters starting at offset using Yul storage access
     */
    function _writeToClusters(
        uint256 storageSlot,
        bytes memory content,
        uint256 offset
    ) private {
        if (content.length == 0) return;
        
        uint256 contentLength = content.length;
        uint256 endOffset = offset + contentLength;
        uint256 startCluster = _getClusterIndex(offset);
        uint256 endCluster = _getClusterIndex(endOffset - 1) + 1;
        uint256 clusterOffset = _getClusterOffset(offset);
        uint256 contentIndex = 0;
        
        for (uint256 clusterIdx = startCluster; clusterIdx < endCluster; clusterIdx++) {
            uint256 clusterSlot = _getClusterSlot(storageSlot, clusterIdx);
            uint256 clusterData = _sload(clusterSlot);
            
            // Calculate how many bytes to write in this cluster
            uint256 bytesInCluster = 32 - clusterOffset;
            if (contentIndex + bytesInCluster > contentLength) {
                bytesInCluster = contentLength - contentIndex;
            }
            
            // Write bytes to cluster (big-endian: first byte at MSB)
            for (uint256 i = 0; i < bytesInCluster; i++) {
                uint256 bytePos = clusterOffset + i;
                uint256 shift = (31 - bytePos) * 8;
                // Clear the byte position
                clusterData &= ~(uint256(0xFF) << shift);
                // Set the byte
                clusterData |= uint256(uint8(content[contentIndex + i])) << shift;
            }
            
            _sstore(clusterSlot, clusterData);
            contentIndex += bytesInCluster;
            clusterOffset = 0; // Reset for subsequent clusters
        }
    }
    
    /**
     * @dev Read bytes from clusters starting at offset using Yul storage access
     */
    function _readFromClusters(
        uint256 storageSlot,
        uint256 offset,
        uint256 length,
        uint32 fileSize
    ) private view returns (bytes memory) {
        if (offset >= fileSize) {
            return new bytes(0);
        }
        
        uint256 actualLength = length;
        if (length == 0 || offset + length > fileSize) {
            actualLength = fileSize - offset;
        }
        
        bytes memory result = new bytes(actualLength);
        uint256 startCluster = _getClusterIndex(offset);
        uint256 endCluster = _getClusterIndex(offset + actualLength - 1) + 1;
        uint256 clusterOffset = _getClusterOffset(offset);
        uint256 resultIndex = 0;
        
        for (uint256 clusterIdx = startCluster; clusterIdx < endCluster; clusterIdx++) {
            uint256 clusterSlot = _getClusterSlot(storageSlot, clusterIdx);
            uint256 clusterData = _sload(clusterSlot);
            
            uint256 bytesInCluster = 32 - clusterOffset;
            if (resultIndex + bytesInCluster > actualLength) {
                bytesInCluster = actualLength - resultIndex;
            }
            
            for (uint256 i = 0; i < bytesInCluster; i++) {
                uint256 bytePos = clusterOffset + i;
                uint256 shift = (31 - bytePos) * 8;
                result[resultIndex + i] = bytes1(uint8((clusterData >> shift) & 0xFF));
            }
            
            resultIndex += bytesInCluster;
            clusterOffset = 0;
        }
        
        return result;
    }
    
    /**
     * @dev Create a new file with optional offset at a specific storage slot
     */
    function createFile(uint256 storageSlot, bytes memory content, uint256 offset) public override {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (,, bool existsFlag,,) = _unpackMetadata(packed);
        require(!existsFlag, "Entry already exists");
        
        uint256 fileSize = offset + content.length;
        require(fileSize <= type(uint32).max, "File too large");
        
        _writeToClusters(storageSlot, content, offset);
        
        uint256 newPacked = _packMetadata(
            msg.sender,
            EntryType.FILE,
            true,
            uint64(block.timestamp),
            uint32(fileSize)
        );
        _sstore(metadataSlot, newPacked);
        
        // Add to entry slots list
        _addEntrySlot(storageSlot);
        
        emit FileCreated(msg.sender, storageSlot, block.timestamp, offset);
    }
    
    /**
     * @dev Create a new directory pointing to another IFileSystem contract at a specific storage slot
     */
    function createDirectory(uint256 storageSlot, address target) public override {
        require(target != address(0), "Invalid target address");
        require(target != address(this), "Cannot point to self");
        
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (,, bool existsFlag,,) = _unpackMetadata(packed);
        require(!existsFlag, "Entry already exists");
        
        uint256 newPacked = _packMetadata(
            msg.sender,
            EntryType.DIRECTORY,
            true,
            uint64(block.timestamp),
            0
        );
        _sstore(metadataSlot, newPacked);
        
        // Store directory target
        uint256 targetSlot = _getDirectoryTargetSlot(storageSlot);
        _sstore(targetSlot, uint256(uint160(target)));
        
        // Add to entry slots list
        _addEntrySlot(storageSlot);
        
        emit DirectoryCreated(msg.sender, storageSlot, target, block.timestamp);
    }
    
    /**
     * @dev Update file content at a specific offset
     */
    function updateFile(uint256 storageSlot, bytes memory content, uint256 offset) public override {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (address owner, EntryType entryType, bool existsFlag, uint64 timestamp, uint32 currentSize) = _unpackMetadata(packed);
        
        if (!existsFlag) {
            revert("Entry does not exist");
        }
        require(owner == msg.sender, "Not owner");
        require(entryType == EntryType.FILE, "Not a file");
        
        uint256 newSize = offset + content.length;
        if (newSize > currentSize) {
            // Extending the file
            newSize = newSize > type(uint32).max ? type(uint32).max : newSize;
        } else if (offset == 0 && content.length < currentSize) {
            // Writing from start with shorter content - truncate to new size
            newSize = content.length;
        } else {
            // Writing in the middle or at end - keep current size to preserve data
            newSize = currentSize;
        }
        
        _writeToClusters(storageSlot, content, offset);
        
        uint256 newPacked = _packMetadata(
            msg.sender,
            EntryType.FILE,
            true,
            uint64(block.timestamp),
            uint32(newSize)
        );
        _sstore(metadataSlot, newPacked);
        
        emit FileUpdated(msg.sender, storageSlot, block.timestamp, offset);
    }
    
    /**
     * @dev Delete an entry (file or directory)
     */
    function deleteEntry(uint256 storageSlot) public override {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (address owner, , bool existsFlag, , ) = _unpackMetadata(packed);
        
        if (!existsFlag) {
            revert("Entry does not exist");
        }
        require(owner == msg.sender, "Not owner");
        
        // Clear metadata
        _sstore(metadataSlot, 0);
        
        // Clear directory target if it's a directory
        uint256 targetSlot = _getDirectoryTargetSlot(storageSlot);
        if (_sload(targetSlot) != 0) {
            _sstore(targetSlot, 0);
        }
        
        // Remove from entry slots list
        _removeEntrySlot(storageSlot);
        
        emit EntryDeleted(msg.sender, storageSlot);
    }
    
    /**
     * @dev Get entry information at a specific storage slot
     */
    function getEntry(uint256 storageSlot) 
        public 
        view 
        override
        returns (
            EntryType entryType,
            address owner,
            bytes memory content,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) 
    {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (owner, entryType, entryExists, timestamp, fileSize) = _unpackMetadata(packed);
        
        // Get directory target if it's a directory
        if (entryExists && entryType == EntryType.DIRECTORY) {
            uint256 targetSlot = _getDirectoryTargetSlot(storageSlot);
            directoryTarget = address(uint160(_sload(targetSlot)));
        }
        
        // Reconstruct content from clusters if it's a file
        if (entryExists && entryType == EntryType.FILE) {
            content = _readFromClusters(storageSlot, 0, 0, uint32(fileSize));
        } else {
            content = new bytes(0);
        }
    }
    
    /**
     * @dev Get all storage slots that have entries in this filesystem
     */
    function getEntries() public view override returns (uint256[] memory) {
        return _getEntrySlots();
    }
    
    /**
     * @dev Check if an entry exists at a specific storage slot
     */
    function exists(uint256 storageSlot) public view override returns (bool) {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (,, bool existsFlag,,) = _unpackMetadata(packed);
        return existsFlag;
    }
    
    /**
     * @dev Read file content at a specific offset
     */
    function readFile(uint256 storageSlot, uint256 offset, uint256 length) 
        public 
        view 
        override
        returns (bytes memory content) 
    {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (, EntryType entryType, bool existsFlag, , uint32 fileSize) = _unpackMetadata(packed);
        
        require(existsFlag, "Entry does not exist");
        require(entryType == EntryType.FILE, "Not a file");
        
        return _readFromClusters(storageSlot, offset, length, fileSize);
    }
    
    /**
     * @dev Write file content at a specific offset
     */
    function writeFile(uint256 storageSlot, uint256 offset, bytes memory content) public override {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (address owner, EntryType entryType, bool existsFlag, , uint32 currentSize) = _unpackMetadata(packed);
        
        if (!existsFlag) {
            // Create new file
            createFile(storageSlot, content, offset);
            return;
        }
        
        require(owner == msg.sender, "Not owner");
        require(entryType == EntryType.FILE, "Not a file");
        
        uint256 newSize = offset + content.length;
        if (newSize > currentSize) {
            newSize = newSize > type(uint32).max ? type(uint32).max : newSize;
        } else if (offset == 0 && content.length < currentSize) {
            newSize = content.length;
        } else {
            newSize = currentSize;
        }
        
        _writeToClusters(storageSlot, content, offset);
        
        uint256 newPacked = _packMetadata(
            msg.sender,
            EntryType.FILE,
            true,
            uint64(block.timestamp),
            uint32(newSize)
        );
        _sstore(metadataSlot, newPacked);
        
        emit FileUpdated(msg.sender, storageSlot, block.timestamp, offset);
    }
    
    /**
     * @dev Read a specific cluster (32-byte chunk) from file storage
     */
    function readCluster(uint256 storageSlot, uint256 clusterIndex) 
        public 
        view 
        override
        returns (uint256 clusterData) 
    {
        uint256 clusterSlot = _getClusterSlot(storageSlot, clusterIndex);
        return _sload(clusterSlot);
    }
    
    /**
     * @dev Add entry slot to enumeration list (using storage slot 3)
     */
    function _addEntrySlot(uint256 storageSlot) private {
        // Get array length slot
        uint256 lengthSlot = SLOT_ENTRY_SLOTS;
        uint256 length = _sload(lengthSlot);
        
        // Calculate slot for new element
        uint256 elementSlot = uint256(keccak256(abi.encodePacked(lengthSlot))) + length;
        _sstore(elementSlot, storageSlot);
        
        // Update length
        _sstore(lengthSlot, length + 1);
    }
    
    /**
     * @dev Remove entry slot from enumeration list
     */
    function _removeEntrySlot(uint256 storageSlot) private {
        uint256 lengthSlot = SLOT_ENTRY_SLOTS;
        uint256 length = _sload(lengthSlot);
        
        // Find and remove
        for (uint256 i = 0; i < length; i++) {
            uint256 elementSlot = uint256(keccak256(abi.encodePacked(lengthSlot))) + i;
            if (_sload(elementSlot) == storageSlot) {
                // Move last element to this position
                if (i < length - 1) {
                    uint256 lastSlot = uint256(keccak256(abi.encodePacked(lengthSlot))) + (length - 1);
                    uint256 lastValue = _sload(lastSlot);
                    _sstore(elementSlot, lastValue);
                }
                // Decrease length
                _sstore(lengthSlot, length - 1);
                break;
            }
        }
    }
    
    /**
     * @dev Get all entry slots
     */
    function _getEntrySlots() private view returns (uint256[] memory) {
        uint256 lengthSlot = SLOT_ENTRY_SLOTS;
        uint256 length = _sload(lengthSlot);
        uint256[] memory slots = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            uint256 elementSlot = uint256(keccak256(abi.encodePacked(lengthSlot))) + i;
            slots[i] = _sload(elementSlot);
        }
        
        return slots;
    }
}
