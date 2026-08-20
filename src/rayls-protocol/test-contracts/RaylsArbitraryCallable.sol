// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import '../../rayls-protocol-sdk/RaylsApp.sol';

contract RaylsArbitraryCallable is RaylsApp {
    string public message;
    uint256 public counter;

    struct User {
        string name;
        uint256 age;
        uint256 balance;
        string email;
        string phoneNumber;
        uint256 registrationDate;
        bool isActive;
        string country;
        uint256 lastLoginTimestamp;
        uint256 totalTransactions;
        string userHash;
        uint256 creditScore;
    }

    mapping(address => User) public users;

    constructor(bytes32 _resourceId, address _endpoint, address _raylsNodeEndpoint) RaylsApp(_endpoint, _raylsNodeEndpoint, address(0)) {
        resourceId = _resourceId;
    }

    function setMessage(string memory _message) public {
        message = _message;
    }

    function getMessage() public view returns (string memory) {
        return message;
    }

    function incrementCounter() public {
        counter++;
    }

    function getCounter() public view returns (uint256) {
        return counter;
    }

    function setUser(
        string memory _name,
        uint256 _age,
        uint256 _balance,
        string memory _email,
        string memory _phoneNumber,
        string memory _country,
        bool _isActive,
        string memory _userHash,
        uint256 _creditScore
    ) public {
        address userAddress = 0x0000000000000000000000000000000000000123;
        uint256 registrationDate = 123;
        uint256 lastLoginTimestamp = 123;
        uint256 totalTransactions = 0;

        users[userAddress] = User({
            name: _name,
            age: _age,
            balance: _balance,
            email: _email,
            phoneNumber: _phoneNumber,
            country: _country,
            isActive: _isActive,
            registrationDate: registrationDate,
            lastLoginTimestamp: lastLoginTimestamp,
            totalTransactions: totalTransactions,
            userHash: _userHash,
            creditScore: _creditScore
        });
    }

}