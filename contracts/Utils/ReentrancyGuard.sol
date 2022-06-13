pragma solidity ^0.8.4;


contract ReentrancyGuard {
    bool public _notEntered;

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    constructor() internal {
        _notEntered = true;
    }
}