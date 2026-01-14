// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFileSystem} from "../../IFileSystem.sol";
import {IERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";

// TODO: Implement the ERC721EnumerableFS contract as a base contract for all ERC721Enumerable contracts

abstract contract ERC721EnumerableFS is IFileSystem {
    IERC721Enumerable public immutable erc721EnumerableContract;

    constructor(address _erc721EnumerableContract) {
        erc721EnumerableContract = IERC721Enumerable(_erc721EnumerableContract);
    }
}