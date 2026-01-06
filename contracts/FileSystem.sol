// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "./IFileSystem.sol";

/**
 * @title FileSystem
 * @dev VFAT-like filesystem contract with packed storage accessed via Yul assembly
 * Data is stored in clusters (32-byte chunks) at specific storage slots
 * Entry metadata is packed into uint256 values for efficiency
 * All storage access uses Yul assembly (sload/sstore) for direct slot manipulation
 */
contract FileSystem is IFileSystem {
    // Constants for dedicated owner and group storage slot
    // Owner and gid are stored together in a single slot
    // Layout: owner (160 bits, bits 96-255) | gid (96 bits, bits 0-95)
    uint256 private constant OWNER_SLOT = uint256(keccak256("SOMETHINGOWNERSLOT"));
    
    // Storage layout:
    // - Entry metadata: stored at storageSlot (packed uint256)
    // - Directory target: stored at storageSlot + 1 (if directory)
    // - File clusters: stored at storageSlot + 2 + clusterIndex
    // - Entry enumeration: mapping to track which slots are used
    // - Owner+GID mapping: stored at keccak256("SOMETHINGOWNERSLOT") + storageSlot
    //   Layout: owner (160 bits, bits 96-255) | gid (96 bits, bits 0-95)
    
    // Base storage slot for entry metadata mapping
    // mapping(uint256 => uint256) entryMetadata; // slot 0
    // mapping(uint256 => address) directoryTargets; // slot 1
    // mapping(uint256 => mapping(uint256 => uint256)) fileClusters; // slot 2
    // uint256[] entrySlots; // slot 3
    
    // Constants for packing/unpacking metadata
    // Layout: entryType (2 bits, bits 94-95) | timestamp (64 bits, bits 30-93) | fileSize (30 bits, bits 0-29)
    // Existence is determined by timestamp > 0
    // EntryType encoding: 00=FILE, 01=DIRECTORY, 10=LINK, 11=reserved
    uint256 private constant MASK_ENTRY_TYPE = 0x0000000000000000000000000000000000000000C00000000000000000000000;
    uint256 private constant MASK_TIMESTAMP = 0x00000000000000000000000000000000000000003FFFFFFFFFFFFFFFC0000000;
    uint256 private constant MASK_FILE_SIZE = 0x000000000000000000000000000000000000000000000000000000003FFFFFFF;
    
    // Storage slot offsets
    uint256 private constant SLOT_ENTRY_METADATA = 0;
    uint256 private constant SLOT_DIRECTORY_TARGETS = 1;
    uint256 private constant SLOT_FILE_CLUSTERS = 2;
    uint256 private constant SLOT_ENTRY_SLOTS = 3;
    uint256 private constant SLOT_NEXT_STORAGE_SLOT = 4; // Tracks next available storage slot (starts at 0)
    uint256 private constant SLOT_FILE_NAMES = 5; // Storage for file names
    
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
     * @dev Get storage slot for file name
     * File names are stored as bytes in a mapping
     * For names longer than 32 bytes, we use multiple slots
     */
    function _getFileNameSlot(uint256 storageSlot, uint256 nameSlotIndex) private pure returns (uint256) {
        // mapping(uint256 => mapping(uint256 => bytes32)) fileNames; // slot 5
        // First mapping: keccak256(abi.encodePacked(storageSlot, SLOT_FILE_NAMES))
        uint256 firstMappingSlot = uint256(keccak256(abi.encodePacked(storageSlot, SLOT_FILE_NAMES)));
        // Second mapping: keccak256(abi.encodePacked(nameSlotIndex, firstMappingSlot))
        return uint256(keccak256(abi.encodePacked(nameSlotIndex, firstMappingSlot)));
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
     * @dev Get storage slot for entry owner and gid
     * mapping(uint256 => uint256) ownerAndGid; // base slot = OWNER_SLOT
     * Layout: owner (160 bits, bits 96-255) | gid (96 bits, bits 0-95)
     */
    function _getOwnerSlot(uint256 storageSlot) private pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(storageSlot, OWNER_SLOT)));
    }
    
    /**
     * @dev Pack owner and gid into uint256
     * Layout: owner (160 bits, bits 96-255) | gid (96 bits, bits 0-95)
     */
    function _packOwnerAndGid(address owner, uint96 gid) private pure returns (uint256) {
        return (uint256(uint160(owner)) << 96) | uint256(gid);
    }
    
    /**
     * @dev Unpack owner and gid from uint256
     */
    function _unpackOwnerAndGid(uint256 packed) private pure returns (address owner, uint96 gid) {
        owner = address(uint160(packed >> 96));
        gid = uint96(packed & 0xFFFFFFFFFFFFFFFFFFFFFFFF);
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
     * Layout: entryType (2 bits) | timestamp (64 bits) | fileSize (30 bits)
     * Existence is determined by timestamp > 0
     * EntryType encoding: 00=FILE, 01=DIRECTORY, 10=LINK, 11=reserved
     */
    function _packMetadata(
        EntryType entryType,
        uint64 timestamp,
        uint32 fileSize
    ) private pure returns (uint256) {
        uint256 packed = 0;
        // EntryType: bits 94-95
        if (entryType == EntryType.DIRECTORY) {
            packed |= uint256(1) << 94; // 01
        } else if (entryType == EntryType.LINK) {
            packed |= uint256(2) << 94; // 10
        }
        // FILE is 00, so no bits set
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
        EntryType entryType,
        uint64 timestamp,
        uint32 fileSize
    ) {
        // EntryType: bits 94-95
        uint256 entryTypeBits = (packed & MASK_ENTRY_TYPE) >> 94;
        if (entryTypeBits == 1) {
            entryType = EntryType.DIRECTORY;
        } else if (entryTypeBits == 2) {
            entryType = EntryType.LINK;
        } else {
            entryType = EntryType.FILE; // 0 or 3 (reserved)
        }
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
     * @dev Write file name to storage slots
     * First slot stores length (1 byte) + first 31 bytes of name
     * Subsequent slots store 32 bytes each
     */
    function _writeFileName(uint256 storageSlot, bytes memory name) private {
        uint256 firstSlot = _getFileNameSlot(storageSlot, 0);
        
        if (name.length == 0) {
            // Store length 0 in first slot
            _sstore(firstSlot, 0);
            return;
        }
        
        uint256 nameLen = name.length;
        require(nameLen <= 255, "Name too long"); // Max 255 bytes
        
        // First slot: store length (1 byte) + first 31 bytes
        uint256 firstSlotData = uint256(nameLen) << 248; // Length in first byte (MSB)
        
        uint256 bytesInFirstSlot = nameLen < 31 ? nameLen : 31;
        for (uint256 j = 0; j < bytesInFirstSlot; j++) {
            uint256 shift = (30 - j) * 8; // Bytes start at position 1 (after length byte)
            firstSlotData |= uint256(uint8(name[j])) << shift;
        }
        _sstore(firstSlot, firstSlotData);
        
        // Remaining slots: store 32 bytes each
        if (nameLen > 31) {
            uint256 remainingBytes = nameLen - 31;
            uint256 numAdditionalSlots = (remainingBytes + 31) / 32;
            
            for (uint256 i = 0; i < numAdditionalSlots; i++) {
                uint256 nameSlot = _getFileNameSlot(storageSlot, i + 1);
                uint256 slotData = 0;
                
                uint256 bytesInSlot = 32;
                if ((i + 1) * 32 > remainingBytes) {
                    bytesInSlot = remainingBytes - (i * 32);
                }
                
                for (uint256 j = 0; j < bytesInSlot; j++) {
                    uint256 shift = (31 - j) * 8;
                    uint256 nameIndex = 31 + i * 32 + j;
                    slotData |= uint256(uint8(name[nameIndex])) << shift;
                }
                
                _sstore(nameSlot, slotData);
            }
        }
    }
    
    /**
     * @dev Read file name from storage slots
     * First slot contains length (1 byte) + first 31 bytes
     * Subsequent slots contain 32 bytes each
     */
    function _readFileName(uint256 storageSlot, uint256 maxLength) private view returns (bytes memory) {
        // Read first slot to get length
        uint256 firstSlot = _getFileNameSlot(storageSlot, 0);
        uint256 firstSlotData = _sload(firstSlot);
        
        if (firstSlotData == 0) {
            return new bytes(0); // Empty name
        }
        
        // Extract length from first byte (MSB)
        uint256 nameLength = uint256(uint8(firstSlotData >> 248));
        
        if (nameLength == 0) {
            return new bytes(0);
        }
        
        // Cap at maxLength if specified
        if (maxLength > 0 && nameLength > maxLength) {
            nameLength = maxLength;
        }
        
        bytes memory name = new bytes(nameLength);
        
        // Read first 31 bytes from first slot (after length byte)
        uint256 bytesFromFirstSlot = nameLength < 31 ? nameLength : 31;
        for (uint256 j = 0; j < bytesFromFirstSlot; j++) {
            uint256 shift = (30 - j) * 8; // Bytes start at position 1
            name[j] = bytes1(uint8((firstSlotData >> shift) & 0xFF));
        }
        
        // Read remaining bytes from additional slots
        if (nameLength > 31) {
            uint256 remainingBytes = nameLength - 31;
            uint256 numAdditionalSlots = (remainingBytes + 31) / 32;
            
            for (uint256 i = 0; i < numAdditionalSlots; i++) {
                uint256 nameSlot = _getFileNameSlot(storageSlot, i + 1);
                uint256 slotData = _sload(nameSlot);
                
                uint256 bytesInSlot = 32;
                if ((i + 1) * 32 > remainingBytes) {
                    bytesInSlot = remainingBytes - (i * 32);
                }
                
                for (uint256 j = 0; j < bytesInSlot; j++) {
                    uint256 bytePos = j;
                    uint256 shift = (31 - bytePos) * 8;
                    uint256 nameIndex = 31 + i * 32 + j;
                    name[nameIndex] = bytes1(uint8((slotData >> shift) & 0xFF));
                }
            }
        }
        
        return name;
    }
    
    /**
     * @dev Get next available storage slot and increment counter
     */
    function _getNextStorageSlot() private returns (uint256) {
        uint256 nextSlot = _sload(SLOT_NEXT_STORAGE_SLOT);
        _sstore(SLOT_NEXT_STORAGE_SLOT, nextSlot + 1);
        return nextSlot;
    }
    
    /**
     * @dev Create a new file with optional offset (storage slot auto-assigned)
     */
    function createFile(bytes memory name, bytes memory body, uint256 offset) public {
        uint256 storageSlot = _getNextStorageSlot();
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (, uint64 timestamp,) = _unpackMetadata(packed);
        require(timestamp == 0, "Entry already exists");
        
        uint256 fileSize = offset + body.length;
        require(fileSize <= type(uint32).max, "File too large");
        
        // Store file name
        _writeFileName(storageSlot, name);
        
        // Store file body (content)
        _writeToClusters(storageSlot, body, offset);
        
        uint256 newPacked = _packMetadata(
            EntryType.FILE,
            uint64(block.timestamp),
            uint32(fileSize)
        );
        _sstore(metadataSlot, newPacked);
        
        // Store owner and gid in dedicated slot (gid defaults to 0)
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        _sstore(ownerSlot, _packOwnerAndGid(msg.sender, 0));
        
        // Add to entry slots list
        _addEntrySlot(storageSlot);
        
        emit FileCreated(msg.sender, storageSlot, block.timestamp, offset);
    }
    
    /**
     * @dev Create a new directory pointing to another IFileSystem contract (storage slot auto-assigned)
     */
    function createDirectory(bytes memory name, address target) public override {
        // Allow address(0) for directories without a specific target (organizational directories)
        // Only require non-zero if target is provided and not self
        if (target != address(0)) {
            require(target != address(this), "Cannot point to self");
        }
        
        uint256 storageSlot = _getNextStorageSlot();
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (, uint64 timestamp,) = _unpackMetadata(packed);
        require(timestamp == 0, "Entry already exists");
        
        // Store directory name
        _writeFileName(storageSlot, name);
        
        uint256 newPacked = _packMetadata(
            EntryType.DIRECTORY,
            uint64(block.timestamp),
            0
        );
        _sstore(metadataSlot, newPacked);
        
        // Store owner and gid in dedicated slot (gid defaults to 0)
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        _sstore(ownerSlot, _packOwnerAndGid(msg.sender, 0));
        
        // Store directory target
        uint256 targetSlot = _getDirectoryTargetSlot(storageSlot);
        _sstore(targetSlot, uint256(uint160(target)));
        
        // Add to entry slots list
        _addEntrySlot(storageSlot);
        
        emit DirectoryCreated(msg.sender, storageSlot, target, block.timestamp);
    }
    
    /**
     * @dev Update file body at a specific offset
     */
    function updateFile(uint256 storageSlot, bytes memory body, uint256 offset) public override {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (EntryType entryType, uint64 timestamp, uint32 currentSize) = _unpackMetadata(packed);
        
        if (timestamp == 0) {
            revert("Entry does not exist");
        }
        
        // Check owner from dedicated slot
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        (address owner, ) = _unpackOwnerAndGid(_sload(ownerSlot));
        require(owner == msg.sender, "Not owner");
        require(entryType == EntryType.FILE, "Not a file");
        
        uint256 newSize = offset + body.length;
        if (newSize > currentSize) {
            // Extending the file
            newSize = newSize > type(uint32).max ? type(uint32).max : newSize;
        } else if (offset == 0 && body.length < currentSize) {
            // Writing from start with shorter body - truncate to new size
            newSize = body.length;
        } else {
            // Writing in the middle or at end - keep current size to preserve data
            newSize = currentSize;
        }
        
        _writeToClusters(storageSlot, body, offset);
        
        uint256 newPacked = _packMetadata(
            EntryType.FILE,
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
        (, uint64 timestamp,) = _unpackMetadata(packed);
        
        if (timestamp == 0) {
            revert("Entry does not exist");
        }
        
        // Check owner from dedicated slot
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        (address owner, ) = _unpackOwnerAndGid(_sload(ownerSlot));
        require(owner == msg.sender, "Not owner");
        
        // Clear metadata (sets timestamp to 0, marking as non-existent)
        _sstore(metadataSlot, 0);
        
        // Clear owner and gid (stored together in same slot)
        _sstore(ownerSlot, 0);
        
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
            bytes memory name,
            bytes memory body,
            uint256 timestamp,
            bool entryExists,
            uint256 fileSize,
            address directoryTarget
        ) 
    {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (entryType, timestamp, fileSize) = _unpackMetadata(packed);
        
        // Existence is determined by timestamp > 0
        entryExists = timestamp > 0;
        
        // Get owner from dedicated slot
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        (owner, ) = _unpackOwnerAndGid(_sload(ownerSlot));
        
        // Get directory target if it's a directory
        if (entryExists && entryType == EntryType.DIRECTORY) {
            uint256 targetSlot = _getDirectoryTargetSlot(storageSlot);
            directoryTarget = address(uint160(_sload(targetSlot)));
        }
        
        // Get name and body based on entry type
        if (entryExists) {
            if (entryType == EntryType.FILE) {
                name = _readFileName(storageSlot, 256);
                body = _readFromClusters(storageSlot, 0, 0, uint32(fileSize));
            } else if (entryType == EntryType.DIRECTORY) {
                name = _readFileName(storageSlot, 256);
                body = new bytes(0);
            } else {
                name = new bytes(0);
                body = new bytes(0);
            }
        } else {
            name = new bytes(0);
            body = new bytes(0);
        }
    }
    
    /**
     * @dev Get entry information at a specific storage slot with pagination support for body content
     */
    function getEntry(uint256 storageSlot, uint256 startingOffset, uint256 maximumLength) 
        public 
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
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (entryType, timestamp, fileSize) = _unpackMetadata(packed);
        
        // Existence is determined by timestamp > 0
        entryExists = timestamp > 0;
        
        // Get owner from dedicated slot
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        (owner, ) = _unpackOwnerAndGid(_sload(ownerSlot));
        
        // Get directory target if it's a directory
        if (entryExists && entryType == EntryType.DIRECTORY) {
            uint256 targetSlot = _getDirectoryTargetSlot(storageSlot);
            directoryTarget = address(uint160(_sload(targetSlot)));
        }
        
        // Get name and body based on entry type
        if (entryExists) {
            if (entryType == EntryType.FILE) {
                name = _readFileName(storageSlot, 256);
                // Read body with pagination support
                body = _readFromClusters(storageSlot, startingOffset, maximumLength, uint32(fileSize));
            } else if (entryType == EntryType.DIRECTORY) {
                name = _readFileName(storageSlot, 256);
                body = new bytes(0);
            } else {
                name = new bytes(0);
                body = new bytes(0);
            }
        } else {
            name = new bytes(0);
            body = new bytes(0);
        }
    }
    
    /**
     * @dev Get all storage slots that have entries in this filesystem
     */
    function getEntries() public view override returns (uint256[] memory) {
        return _getEntrySlots();
    }
    
    /**
     * @dev Get storage slots with pagination support
     */
    function getEntries(uint256 startingOffset, uint256 maximumLength) 
        public 
        view 
        override
        returns (uint256[] memory) 
    {
        uint256[] memory allSlots = _getEntrySlots();
        uint256 totalCount = allSlots.length;
        
        // Handle out of bounds offset
        if (startingOffset >= totalCount) {
            return new uint256[](0);
        }
        
        // Calculate actual length to return
        uint256 remainingCount = totalCount - startingOffset;
        uint256 actualLength = maximumLength;
        if (maximumLength == 0 || maximumLength > remainingCount) {
            actualLength = remainingCount;
        }
        
        // Create result array and copy slots
        uint256[] memory result = new uint256[](actualLength);
        for (uint256 i = 0; i < actualLength; i++) {
            result[i] = allSlots[startingOffset + i];
        }
        
        return result;
    }
    
    /**
     * @dev Get the total count of entries in this filesystem
     */
    function getEntryCount() public view override returns (uint256) {
        uint256 lengthSlot = SLOT_ENTRY_SLOTS;
        return _sload(lengthSlot);
    }
    
    /**
     * @dev Get the size of a file at a specific storage slot
     */
    function getFileSize(uint256 storageSlot) public view override returns (uint256 fileSize) {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (, , fileSize) = _unpackMetadata(packed);
    }
    
    /**
     * @dev Check if an entry exists at a specific storage slot
     */
    function exists(uint256 storageSlot) public view override returns (bool) {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (, uint64 timestamp,) = _unpackMetadata(packed);
        return timestamp > 0;
    }
    
    /**
     * @dev Read file body at a specific offset
     */
    function readFile(uint256 storageSlot, uint256 offset, uint256 length) 
        public 
        view 
        override
        returns (bytes memory body) 
    {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (EntryType entryType, uint64 timestamp, uint32 fileSize) = _unpackMetadata(packed);
        
        require(timestamp > 0, "Entry does not exist");
        require(entryType == EntryType.FILE, "Not a file");
        
        return _readFromClusters(storageSlot, offset, length, fileSize);
    }
    
    /**
     * @dev Write file body at a specific offset
     */
    function writeFile(uint256 storageSlot, uint256 offset, bytes memory body) public override {
        uint256 metadataSlot = _getMetadataSlot(storageSlot);
        uint256 packed = _sload(metadataSlot);
        (EntryType entryType, uint64 timestamp, uint32 currentSize) = _unpackMetadata(packed);
        
        if (timestamp == 0) {
            // Create new file (will auto-assign storage slot)
            // Use empty name if creating via writeFile
            createFile(bytes(""), body, offset);
            return;
        }
        
        // Check owner from dedicated slot
        uint256 ownerSlot = _getOwnerSlot(storageSlot);
        (address owner, ) = _unpackOwnerAndGid(_sload(ownerSlot));
        require(owner == msg.sender, "Not owner");
        require(entryType == EntryType.FILE, "Not a file");
        
        uint256 newSize = offset + body.length;
        if (newSize > currentSize) {
            newSize = newSize > type(uint32).max ? type(uint32).max : newSize;
        } else if (offset == 0 && body.length < currentSize) {
            newSize = body.length;
        } else {
            newSize = currentSize;
        }
        
        _writeToClusters(storageSlot, body, offset);
        
        uint256 newPacked = _packMetadata(
            EntryType.FILE,
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
