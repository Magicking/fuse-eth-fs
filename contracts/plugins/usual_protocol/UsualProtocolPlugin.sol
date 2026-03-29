// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFileSystem} from "../../IFileSystem.sol";
import {IRPCProxyPlugin} from "../rpc_proxy/IRPCProxyPlugin.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IUsualRegistry {
    function getContract(bytes32 name) external view returns (address);
}

/**
 * @title UsualProtocolPlugin
 * @dev RPC proxy plugin that exposes all metrics from the Usual Protocol contracts.
 * Instantiated via a RegistryContract address. Metrics are organized in a directory
 * structure mirroring the core-protocol source layout:
 *
 *   token/usd0/          - USD0 stablecoin metrics
 *   token/usd0pp/        - USD0++ bond token metrics
 *   token/usual/         - USUAL governance token metrics
 *   token/usualS/        - USUAL* snapshot token metrics
 *   token/usualSP/       - USUAL* vesting contract metrics
 *   vaults/usualX/       - UsualX ERC4626 vault metrics
 *   vaults/usualXLockup/ - UsualX lockup mechanism metrics
 *   daoCollateral/       - DAO collateral / RWA swap metrics
 *   swapperEngine/       - USDC/USD0 order matching metrics
 *   distribution/        - USUAL distribution module metrics
 *   modules/yieldModule/ - Yield module metrics
 *   oracles/             - Oracle metrics
 */
contract UsualProtocolPlugin is IRPCProxyPlugin {
    using Strings for uint256;

    // ============ Types ============

    enum FormatType {
        UINT256,        // raw uint256
        UINT256_18DEC,  // uint256 / 1e18 with decimal point
        UINT256_6DEC,   // uint256 / 1e6 with decimal point
        BOOL,           // "true" or "false"
        BPS,            // basis points -> "XX.XX%"
        TIMESTAMP,      // unix timestamp (seconds)
        STRING_RESULT,  // ABI-encoded string return
        UINT8_RESULT,   // uint8 value (e.g. decimals)
        BUCKETS,        // getBucketsDistribution() -> 9 uint256s
        THREE_UINT256,  // getFeeRates() -> 3 uint256s
        FIVE_UINT256,   // calculateUsualDist() -> 5 uint256s
        PAUSED_STATUS   // BATCH_CALL: paused() across all 11 contracts -> summary
    }

    struct MetricDef {
        bytes32 registryKey;
        bytes4 selector;
        FormatType formatType;
    }

    // ============ State ============

    IUsualRegistry public immutable registry;
    uint256 public immutable metricCount;
    uint256 public immutable dirCount;
    uint256 public immutable totalEntries; // metricCount + dirCount

    MetricDef[] private _metrics;
    string[] private _metricNames;
    string[] private _dirNames;

    // ============ Registry Keys (matching core-protocol constants.sol) ============

    bytes32 private constant K_USD0 = keccak256("CONTRACT_USD0");
    bytes32 private constant K_USD0PP = keccak256("CONTRACT_USD0PP");
    bytes32 private constant K_USUAL = keccak256("CONTRACT_USUAL");
    bytes32 private constant K_USUALS = keccak256("CONTRACT_USUALS");
    bytes32 private constant K_USUALSP = keccak256("CONTRACT_USUALSP");
    bytes32 private constant K_USUALX = keccak256("CONTRACT_USUALX");
    bytes32 private constant K_USUALX_LOCKUP = keccak256("CONTRACT_USUALX_LOCKUP");
    bytes32 private constant K_DAO_COLLATERAL = keccak256("CONTRACT_DAO_COLLATERAL");
    bytes32 private constant K_SWAPPER_ENGINE = keccak256("CONTRACT_SWAPPER_ENGINE");
    bytes32 private constant K_DISTRIBUTION = keccak256("CONTRACT_DISTRIBUTION_MODULE");
    bytes32 private constant K_YIELD_MODULE = keccak256("CONTRACT_YIELD_MODULE");
    bytes32 private constant K_ORACLE = keccak256("CONTRACT_ORACLE");

    // ============ Errors ============

    error NotImplemented();
    error SlotOutOfRange();

    // ============ Constructor ============

    constructor(address _registry) {
        registry = IUsualRegistry(_registry);
        _initMetrics();
        _initDirs();
        metricCount = _metrics.length;
        dirCount = _dirNames.length;
        totalEntries = _metrics.length + _dirNames.length;
    }

    // ============ IRPCProxyPlugin ============

    function isRPCProxy() external pure override returns (bool) {
        return true;
    }

    function getRPCDescriptor(uint256 storageSlot)
        external
        view
        override
        returns (RPCDescriptor memory descriptor)
    {
        // Only file metrics have RPC descriptors, not directories
        if (storageSlot >= metricCount) revert SlotOutOfRange();

        MetricDef storage m = _metrics[storageSlot];

        if (m.formatType == FormatType.PAUSED_STATUS) {
            return _buildPausedStatusDescriptor();
        }

        descriptor = RPCDescriptor({
            callType: RPCCallType.CALL,
            targetAddress: registry.getContract(m.registryKey),
            callData: abi.encodePacked(m.selector),
            blockNumber: 0 // latest
        });
    }

    function _buildPausedStatusDescriptor() internal view returns (RPCDescriptor memory) {
        bytes memory pausedCall = abi.encodePacked(bytes4(keccak256("paused()")));
        address[] memory targets = new address[](11);
        bytes[] memory calldatas = new bytes[](11);
        targets[0]  = registry.getContract(K_USD0);          calldatas[0]  = pausedCall;
        targets[1]  = registry.getContract(K_USD0PP);        calldatas[1]  = pausedCall;
        targets[2]  = registry.getContract(K_USUAL);         calldatas[2]  = pausedCall;
        targets[3]  = registry.getContract(K_USUALS);        calldatas[3]  = pausedCall;
        targets[4]  = registry.getContract(K_USUALSP);       calldatas[4]  = pausedCall;
        targets[5]  = registry.getContract(K_USUALX);        calldatas[5]  = pausedCall;
        targets[6]  = registry.getContract(K_USUALX_LOCKUP); calldatas[6]  = pausedCall;
        targets[7]  = registry.getContract(K_DAO_COLLATERAL);calldatas[7]  = pausedCall;
        targets[8]  = registry.getContract(K_SWAPPER_ENGINE);calldatas[8]  = pausedCall;
        targets[9]  = registry.getContract(K_DISTRIBUTION);  calldatas[9]  = pausedCall;
        targets[10] = registry.getContract(K_YIELD_MODULE);  calldatas[10] = pausedCall;
        return RPCDescriptor({
            callType: RPCCallType.BATCH_CALL,
            targetAddress: address(0),
            callData: abi.encode(targets, calldatas),
            blockNumber: 0
        });
    }

    function formatRPCResult(uint256 storageSlot, bytes memory rpcResult)
        external
        view
        override
        returns (bytes memory formattedContent)
    {
        if (storageSlot >= metricCount) revert SlotOutOfRange();

        MetricDef storage m = _metrics[storageSlot];
        string storage name = _metricNames[storageSlot];

        formattedContent = _formatValue(rpcResult, m.formatType, name);
    }

    // ============ IFileSystem ============

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
        if (storageSlot >= totalEntries) {
            return (EntryType.FILE, address(0), "", "", 0, false, 0, address(0));
        }

        // Directory entries (slots >= metricCount)
        if (storageSlot >= metricCount) {
            uint256 dirIdx = storageSlot - metricCount;
            return (
                EntryType.DIRECTORY,
                address(this),
                bytes(_dirNames[dirIdx]),
                "",
                block.timestamp,
                true,
                0,
                address(0)
            );
        }

        // File metric entries
        return (
            EntryType.FILE,
            address(this),
            bytes(_metricNames[storageSlot]),
            "",
            block.timestamp,
            true,
            0, // Dynamic via RPC proxy
            address(0)
        );
    }

    function getEntries() external view override returns (uint256[] memory) {
        uint256[] memory entries = new uint256[](totalEntries);
        for (uint256 i = 0; i < totalEntries; i++) {
            entries[i] = i;
        }
        return entries;
    }

    function getEntryCount() external view override returns (uint256) {
        return totalEntries;
    }

    function getEntriesPaginated(uint256 offset, uint256 limit)
        external
        view
        override
        returns (uint256[] memory)
    {
        if (offset >= totalEntries) return new uint256[](0);

        uint256 remaining = totalEntries - offset;
        uint256 count = limit < remaining ? limit : remaining;
        uint256[] memory entries = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            entries[i] = offset + i;
        }
        return entries;
    }

    function exists(uint256 storageSlot) external view override returns (bool) {
        return storageSlot < totalEntries;
    }

    function readFile(uint256, uint256, uint256) external pure override returns (bytes memory) {
        return ""; // RPC proxy handles reads
    }

    function readCluster(uint256, uint256) external pure override returns (uint256) {
        return 0;
    }

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

    // ============ Metric Initialization ============

    function _add(bytes32 key, bytes4 sel, string memory name, FormatType fmt) internal {
        _metrics.push(MetricDef({registryKey: key, selector: sel, formatType: fmt}));
        _metricNames.push(name);
    }

    function _initMetrics() internal {
        // ── token/usd0/ ──
        _add(K_USD0, bytes4(keccak256("totalSupply()")),  "token/usd0/totalSupply",  FormatType.UINT256_18DEC);
        _add(K_USD0, bytes4(keccak256("name()")),          "token/usd0/name",          FormatType.STRING_RESULT);
        _add(K_USD0, bytes4(keccak256("symbol()")),        "token/usd0/symbol",        FormatType.STRING_RESULT);
        _add(K_USD0, bytes4(keccak256("paused()")),        "token/usd0/paused",        FormatType.BOOL);
        _add(K_USD0, bytes4(keccak256("decimals()")),      "token/usd0/decimals",      FormatType.UINT8_RESULT);

        // ── token/usd0pp/ ──
        _add(K_USD0PP, bytes4(keccak256("totalSupply()")),                    "token/usd0pp/totalSupply",                    FormatType.UINT256_18DEC);
        _add(K_USD0PP, bytes4(keccak256("name()")),                            "token/usd0pp/name",                            FormatType.STRING_RESULT);
        _add(K_USD0PP, bytes4(keccak256("symbol()")),                          "token/usd0pp/symbol",                          FormatType.STRING_RESULT);
        _add(K_USD0PP, bytes4(keccak256("paused()")),                          "token/usd0pp/paused",                          FormatType.BOOL);
        _add(K_USD0PP, bytes4(keccak256("getStartTime()")),                    "token/usd0pp/startTime",                      FormatType.TIMESTAMP);
        _add(K_USD0PP, bytes4(keccak256("getEndTime()")),                      "token/usd0pp/endTime",                        FormatType.TIMESTAMP);
        _add(K_USD0PP, bytes4(keccak256("getFloorPrice()")),                   "token/usd0pp/floorPrice",                     FormatType.UINT256_18DEC);
        _add(K_USD0PP, bytes4(keccak256("getDurationCostFactor()")),           "token/usd0pp/durationCostFactor",             FormatType.UINT256);
        _add(K_USD0PP, bytes4(keccak256("getUsualDistributionPerUsd0pp()")),   "token/usd0pp/usualDistributionPerUsd0pp",     FormatType.UINT256_18DEC);
        _add(K_USD0PP, bytes4(keccak256("getAccumulatedFees()")),              "token/usd0pp/accumulatedFees",                FormatType.UINT256_18DEC);

        // ── token/usual/ ──
        _add(K_USUAL, bytes4(keccak256("totalSupply()")),  "token/usual/totalSupply",  FormatType.UINT256_18DEC);
        _add(K_USUAL, bytes4(keccak256("name()")),          "token/usual/name",          FormatType.STRING_RESULT);
        _add(K_USUAL, bytes4(keccak256("symbol()")),        "token/usual/symbol",        FormatType.STRING_RESULT);
        _add(K_USUAL, bytes4(keccak256("paused()")),        "token/usual/paused",        FormatType.BOOL);

        // ── token/usualS/ ──
        _add(K_USUALS, bytes4(keccak256("totalSupply()")),  "token/usualS/totalSupply",  FormatType.UINT256_18DEC);
        _add(K_USUALS, bytes4(keccak256("name()")),          "token/usualS/name",          FormatType.STRING_RESULT);
        _add(K_USUALS, bytes4(keccak256("symbol()")),        "token/usualS/symbol",        FormatType.STRING_RESULT);
        _add(K_USUALS, bytes4(keccak256("paused()")),        "token/usualS/paused",        FormatType.BOOL);

        // ── token/usualSP/ ──
        _add(K_USUALSP, bytes4(keccak256("totalStaked()")),  "token/usualSP/totalStaked",  FormatType.UINT256_18DEC);
        _add(K_USUALSP, bytes4(keccak256("getDuration()")),  "token/usualSP/duration",     FormatType.UINT256);
        _add(K_USUALSP, bytes4(keccak256("paused()")),       "token/usualSP/paused",       FormatType.BOOL);

        // ── vaults/usualX/ ──
        _add(K_USUALX, bytes4(keccak256("totalSupply()")),    "vaults/usualX/totalSupply",    FormatType.UINT256_18DEC);
        _add(K_USUALX, bytes4(keccak256("totalAssets()")),    "vaults/usualX/totalAssets",    FormatType.UINT256_18DEC);
        _add(K_USUALX, bytes4(keccak256("withdrawFeeBps()")), "vaults/usualX/withdrawFeeBps", FormatType.BPS);
        _add(K_USUALX, bytes4(keccak256("name()")),            "vaults/usualX/name",            FormatType.STRING_RESULT);
        _add(K_USUALX, bytes4(keccak256("symbol()")),          "vaults/usualX/symbol",          FormatType.STRING_RESULT);
        _add(K_USUALX, bytes4(keccak256("paused()")),          "vaults/usualX/paused",          FormatType.BOOL);

        // ── vaults/usualXLockup/ ──
        _add(K_USUALX_LOCKUP, bytes4(keccak256("paused()")), "vaults/usualXLockup/paused", FormatType.BOOL);

        // ── daoCollateral/ ──
        _add(K_DAO_COLLATERAL, bytes4(keccak256("redeemFee()")),       "daoCollateral/redeemFee",       FormatType.BPS);
        _add(K_DAO_COLLATERAL, bytes4(keccak256("isCBROn()")),         "daoCollateral/isCBROn",         FormatType.BOOL);
        _add(K_DAO_COLLATERAL, bytes4(keccak256("cbrCoef()")),         "daoCollateral/cbrCoef",         FormatType.UINT256);
        _add(K_DAO_COLLATERAL, bytes4(keccak256("isRedeemPaused()")),  "daoCollateral/isRedeemPaused",  FormatType.BOOL);
        _add(K_DAO_COLLATERAL, bytes4(keccak256("isSwapPaused()")),    "daoCollateral/isSwapPaused",    FormatType.BOOL);
        _add(K_DAO_COLLATERAL, bytes4(keccak256("nonceThreshold()")),  "daoCollateral/nonceThreshold",  FormatType.UINT256);

        // ── swapperEngine/ ──
        _add(K_SWAPPER_ENGINE, bytes4(keccak256("minimumUSDCAmountProvided()")), "swapperEngine/minimumUSDCAmountProvided", FormatType.UINT256_6DEC);
        _add(K_SWAPPER_ENGINE, bytes4(keccak256("paused()")),                     "swapperEngine/paused",                     FormatType.BOOL);

        // ── distribution/ ──
        _add(K_DISTRIBUTION, bytes4(keccak256("getBucketsDistribution()")),             "distribution/bucketsDistribution",             FormatType.BUCKETS);
        _add(K_DISTRIBUTION, bytes4(keccak256("getLastOnChainDistributionTimestamp()")), "distribution/lastOnChainDistributionTimestamp", FormatType.TIMESTAMP);
        _add(K_DISTRIBUTION, bytes4(keccak256("getOffChainDistributionMintCap()")),      "distribution/offChainDistributionMintCap",      FormatType.UINT256_18DEC);
        _add(K_DISTRIBUTION, bytes4(keccak256("calculateRt()")),                         "distribution/calculateRt",                      FormatType.UINT256_18DEC);
        _add(K_DISTRIBUTION, bytes4(keccak256("calculateKappa()")),                      "distribution/calculateKappa",                   FormatType.UINT256_18DEC);
        _add(K_DISTRIBUTION, bytes4(keccak256("calculateGamma()")),                      "distribution/calculateGamma",                   FormatType.UINT256_18DEC);
        _add(K_DISTRIBUTION, bytes4(keccak256("paused()")),                              "distribution/paused",                           FormatType.BOOL);

        // ── distribution/allocator/ ──
        _add(K_DISTRIBUTION, bytes4(keccak256("getD()")),         "distribution/allocator/d",         FormatType.UINT256);
        _add(K_DISTRIBUTION, bytes4(keccak256("getM0()")),        "distribution/allocator/m0",        FormatType.UINT256_18DEC);
        _add(K_DISTRIBUTION, bytes4(keccak256("getRateMin()")),   "distribution/allocator/rateMin",   FormatType.BPS);
        _add(K_DISTRIBUTION, bytes4(keccak256("getBaseGamma()")), "distribution/allocator/baseGamma", FormatType.BPS);
        _add(K_DISTRIBUTION, bytes4(keccak256("getFeeRates()")),  "distribution/allocator/feeRates",  FormatType.THREE_UINT256);

        // ── modules/yieldModule/ ──
        _add(K_YIELD_MODULE, bytes4(keccak256("getMaxDataAge()")),            "modules/yieldModule/maxDataAge",            FormatType.UINT256);
        _add(K_YIELD_MODULE, bytes4(keccak256("getBlendedWeeklyInterest()")), "modules/yieldModule/blendedWeeklyInterest", FormatType.BPS);
        _add(K_YIELD_MODULE, bytes4(keccak256("getP90InterestRate()")),       "modules/yieldModule/p90InterestRate",       FormatType.BPS);
        _add(K_YIELD_MODULE, bytes4(keccak256("getTreasuryCount()")),         "modules/yieldModule/treasuryCount",         FormatType.UINT256);
        _add(K_YIELD_MODULE, bytes4(keccak256("getYieldSourceCount()")),      "modules/yieldModule/yieldSourceCount",      FormatType.UINT256);
        _add(K_YIELD_MODULE, bytes4(keccak256("paused()")),                   "modules/yieldModule/paused",                FormatType.BOOL);

        // ── oracles/ ──
        _add(K_ORACLE, bytes4(keccak256("getMaxDepegThreshold()")), "oracles/maxDepegThreshold", FormatType.UINT256);

        // ── status/ ── Cross-contract pause health check (BATCH_CALL)
        _add(bytes32(0), bytes4(0), "status/paused", FormatType.PAUSED_STATUS);
    }

    function _initDirs() internal {
        // Explicit directory entries for all intermediate paths
        // Required so the FUSE layer can resolve getattr on subdirectories
        _dirNames.push("token");
        _dirNames.push("token/usd0");
        _dirNames.push("token/usd0pp");
        _dirNames.push("token/usual");
        _dirNames.push("token/usualS");
        _dirNames.push("token/usualSP");
        _dirNames.push("vaults");
        _dirNames.push("vaults/usualX");
        _dirNames.push("vaults/usualXLockup");
        _dirNames.push("daoCollateral");
        _dirNames.push("swapperEngine");
        _dirNames.push("distribution");
        _dirNames.push("distribution/allocator");
        _dirNames.push("modules");
        _dirNames.push("modules/yieldModule");
        _dirNames.push("oracles");
        _dirNames.push("status");
    }

    // ============ Formatting ============

    function _formatValue(bytes memory raw, FormatType fmt, string storage name)
        internal
        view
        returns (bytes memory)
    {
        if (fmt == FormatType.UINT256) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.UINT256_18DEC) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", _formatDecimals(val, 18), "\n");
        }

        if (fmt == FormatType.UINT256_6DEC) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", _formatDecimals(val, 6), "\n");
        }

        if (fmt == FormatType.BOOL) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", val != 0 ? "true" : "false", "\n");
        }

        if (fmt == FormatType.BPS) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", _formatBps(val), "\n");
        }

        if (fmt == FormatType.TIMESTAMP) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.STRING_RESULT) {
            string memory val = _decodeString(raw);
            return abi.encodePacked(name, "\n", val, "\n");
        }

        if (fmt == FormatType.UINT8_RESULT) {
            uint256 val = _decodeUint256(raw);
            return abi.encodePacked(name, "\n", val.toString(), "\n");
        }

        if (fmt == FormatType.BUCKETS) {
            return _formatBuckets(raw, name);
        }

        if (fmt == FormatType.THREE_UINT256) {
            return _formatThreeUint256(raw, name);
        }

        if (fmt == FormatType.FIVE_UINT256) {
            return _formatFiveUint256(raw, name);
        }

        if (fmt == FormatType.PAUSED_STATUS) {
            return _formatPausedStatus(raw, name);
        }

        return abi.encodePacked(name, "\n", _toHexString(raw), "\n");
    }

    function _formatBuckets(bytes memory raw, string storage name)
        internal
        pure
        returns (bytes memory)
    {
        // getBucketsDistribution() returns 9 uint256 values
        // Split into two abi.encodePacked calls to avoid stack-too-deep
        bytes memory part1 = abi.encodePacked(
            name, "\n",
            "lbt:          ", _formatBps(_decodeUint256At(raw, 0)), "\n",
            "lyt:          ", _formatBps(_decodeUint256At(raw, 32)), "\n",
            "iyt:          ", _formatBps(_decodeUint256At(raw, 64)), "\n",
            "bribe:        ", _formatBps(_decodeUint256At(raw, 96)), "\n",
            "eco:          ", _formatBps(_decodeUint256At(raw, 128)), "\n"
        );
        bytes memory part2 = abi.encodePacked(
            "dao:          ", _formatBps(_decodeUint256At(raw, 160)), "\n",
            "marketMakers: ", _formatBps(_decodeUint256At(raw, 192)), "\n",
            "usualX:       ", _formatBps(_decodeUint256At(raw, 224)), "\n",
            "usualStar:    ", _formatBps(_decodeUint256At(raw, 256)), "\n"
        );
        return abi.encodePacked(part1, part2);
    }

    function _formatThreeUint256(bytes memory raw, string storage name)
        internal
        pure
        returns (bytes memory)
    {
        // getFeeRates() returns (treasuryRate, usualXRate, usualStarRate)
        uint256 v0 = _decodeUint256At(raw, 0);
        uint256 v1 = _decodeUint256At(raw, 32);
        uint256 v2 = _decodeUint256At(raw, 64);
        return abi.encodePacked(
            name, "\n",
            "treasuryRate: ", _formatBps(v0), "\n",
            "usualXRate:   ", _formatBps(v1), "\n",
            "usualStarRate:", _formatBps(v2), "\n"
        );
    }

    function _formatFiveUint256(bytes memory raw, string storage name)
        internal
        pure
        returns (bytes memory)
    {
        // calculateUsualDist() returns (st, rt, kappa, mt, usualDist)
        uint256 v0 = _decodeUint256At(raw, 0);
        uint256 v1 = _decodeUint256At(raw, 32);
        uint256 v2 = _decodeUint256At(raw, 64);
        uint256 v3 = _decodeUint256At(raw, 96);
        uint256 v4 = _decodeUint256At(raw, 128);
        return abi.encodePacked(
            name, "\n",
            "st:        ", _formatDecimals(v0, 18), "\n",
            "rt:        ", _formatDecimals(v1, 18), "\n",
            "kappa:     ", _formatDecimals(v2, 18), "\n",
            "mt:        ", _formatDecimals(v3, 18), "\n",
            "usualDist: ", _formatDecimals(v4, 18), "\n"
        );
    }

    // ============ Decoding Helpers ============

    function _decodeUint256(bytes memory data) internal pure returns (uint256 val) {
        if (data.length < 32) return 0;
        assembly {
            val := mload(add(data, 32))
        }
    }

    function _decodeUint256At(bytes memory data, uint256 offset) internal pure returns (uint256 val) {
        if (data.length < offset + 32) return 0;
        assembly {
            val := mload(add(add(data, 32), offset))
        }
    }

    function _decodeString(bytes memory data) internal pure returns (string memory) {
        if (data.length < 64) return "";
        // ABI-encoded string: offset (32) + length (32) + data
        uint256 offset;
        assembly {
            offset := mload(add(data, 32))
        }
        uint256 strLen;
        assembly {
            strLen := mload(add(add(data, 32), offset))
        }
        if (strLen == 0 || data.length < offset + 32 + strLen) return "";
        bytes memory strBytes = new bytes(strLen);
        for (uint256 i = 0; i < strLen; i++) {
            strBytes[i] = data[32 + offset + 32 + i];
        }
        return string(strBytes);
    }

    // ============ Formatting Helpers ============

    function _formatDecimals(uint256 value, uint256 dec) internal pure returns (string memory) {
        uint256 divisor = 10 ** dec;
        uint256 intPart = value / divisor;
        uint256 fracPart = value % divisor;

        string memory intStr = intPart.toString();
        string memory fracStr = _padLeft(fracPart.toString(), dec);

        return string(abi.encodePacked(intStr, ".", fracStr));
    }

    function _formatBps(uint256 bps) internal pure returns (string memory) {
        // bps / 100 = percentage with 2 decimal places
        uint256 intPart = bps / 100;
        uint256 fracPart = bps % 100;
        return string(abi.encodePacked(intPart.toString(), ".", _padLeft(fracPart.toString(), 2), "%"));
    }

    function _padLeft(string memory s, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;

        uint256 padLen = width - b.length;
        bytes memory padded = new bytes(width);
        for (uint256 i = 0; i < padLen; i++) {
            padded[i] = "0";
        }
        for (uint256 i = 0; i < b.length; i++) {
            padded[padLen + i] = b[i];
        }
        return string(padded);
    }

    function _formatPausedStatus(bytes memory raw, string storage name)
        internal
        pure
        returns (bytes memory)
    {
        bytes[] memory results = abi.decode(raw, (bytes[]));
        bytes memory part1 = abi.encodePacked(
            name, "\n",
            "usd0:          ", _boolResult(results, 0), "\n",
            "usd0pp:        ", _boolResult(results, 1), "\n",
            "usual:         ", _boolResult(results, 2), "\n",
            "usualS:        ", _boolResult(results, 3), "\n",
            "usualSP:       ", _boolResult(results, 4), "\n",
            "usualX:        ", _boolResult(results, 5), "\n"
        );
        bytes memory part2 = abi.encodePacked(
            "usualXLockup:  ", _boolResult(results, 6),  "\n",
            "daoCollateral: ", _boolResult(results, 7),  "\n",
            "swapperEngine: ", _boolResult(results, 8),  "\n",
            "distribution:  ", _boolResult(results, 9),  "\n",
            "yieldModule:   ", _boolResult(results, 10), "\n"
        );
        return abi.encodePacked(part1, part2);
    }

    function _boolResult(bytes[] memory results, uint256 idx) internal pure returns (string memory) {
        if (idx >= results.length || results[idx].length < 32) return "?";
        uint256 val;
        bytes memory r = results[idx];
        assembly { val := mload(add(r, 32)) }
        return val != 0 ? "true" : "false";
    }

    function _toHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        uint256 len = data.length > 32 ? 32 : data.length;
        bytes memory result = new bytes(2 + len * 2);
        result[0] = "0";
        result[1] = "x";
        for (uint256 i = 0; i < len; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i]) >> 4];
            result[3 + i * 2] = hexChars[uint8(data[i]) & 0x0f];
        }
        return string(result);
    }
}
