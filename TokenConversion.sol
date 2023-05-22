// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "Nova.sol";
import "TimeLock.sol";

contract TokenConversion is Ownable, TimeLock {
    IERC20 immutable public dogiraToken; //assumes 9 Decimal Token
    IERC20 immutable public novaToken;
    uint256 immutable public tokenConversionDeadline;
    address constant public DEAD = 0x000000000000000000000000000000000000dEaD;

    event TokensConverted(address _address, uint256 _tokensConverted);

    constructor(address _dogiraToken, address _novaToken) {
        tokenConversionDeadline = block.timestamp + 90 days;
        dogiraToken = IERC20(_dogiraToken);
        novaToken = IERC20(_novaToken);
    }

    function convert(uint256 amount) external {
        require(block.timestamp <= tokenConversionDeadline, "Conversion period has ended");
        require(dogiraToken.transferFrom(msg.sender, address(this), amount), "Transfer of old tokens failed");
        require(dogiraToken.transfer(DEAD, amount), "Burning old tokens failed");
        
        // Convert to equivalent amount of new tokens, accounting for 9dec -> 18dec conversion
        uint256 newTokenAmount = amount * 10**9;
        require(novaToken.balanceOf(address(this)) >= newTokenAmount, "Insufficient amount of tokens");
        require(novaToken.transfer(msg.sender, newTokenAmount), "Transfer of tokens failed");
        emit TokensConverted(msg.sender, amount);
    }

    function withdraw() external onlyOwner withTimelock("withdraw") {
        require(block.timestamp > tokenConversionDeadline, "Conversion period has not yet ended");
        uint256 balance = novaToken.balanceOf(address(this));
        require(novaToken.transfer(owner(), balance), "Transfer to owner failed");
    }

    function burn() external onlyOwner withTimelock("burn") {
        require(block.timestamp > tokenConversionDeadline, "Conversion period has not yet ended");
        uint256 balance = novaToken.balanceOf(address(this));
        require(balance > 0, "No tokens to burn");
        address payable novaTokenPayable = payable(address(novaToken));
        Nova(novaTokenPayable).burn(balance);
    }
}