// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockBadERC20
 * @notice ERC20 that returns false on transfer/transferFrom instead of reverting.
 * @dev Used to test unchecked-transfer vulnerability (Slither high #3, #4).
 *      Some real tokens (e.g., USDT) behave this way.
 */
contract MockBadERC20 is IERC20 {
    string public name = "BadToken";
    string public symbol = "BAD";
    uint8 public decimals = 18;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;

    bool public shouldFailTransfer;
    bool public shouldFailTransferFrom;

    constructor() {
        _totalSupply = 1_000_000 * 10 ** 18;
        _balances[msg.sender] = _totalSupply;
    }

    function setFailTransfer(bool _fail) external {
        shouldFailTransfer = _fail;
    }

    function setFailTransferFrom(bool _fail) external {
        shouldFailTransferFrom = _fail;
    }

    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (shouldFailTransfer) {
            return false; // Silent failure - does NOT revert
        }
        _balances[msg.sender] -= amount;
        _balances[to] += amount;
        return true;
    }

    function allowance(address owner, address spender) external view override returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (shouldFailTransferFrom) {
            return false; // Silent failure - does NOT revert
        }
        _allowances[from][msg.sender] -= amount;
        _balances[from] -= amount;
        _balances[to] += amount;
        return true;
    }
}
