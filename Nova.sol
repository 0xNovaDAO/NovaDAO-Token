// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "TimeLock.sol";

contract Nova is ERC20, Ownable, TimeLock {
    string constant private _name = "Nova DAO";
    string constant private _symbol = "NOVA";
    uint256 constant private _decimals = 18;
    address constant public DEAD = 0x000000000000000000000000000000000000dEaD;
    
    address public daoWallet;
    uint256 public allowedSlippage = 0;
    uint256 public taxForLiquidity = 1;
    uint256 public taxForDao = 2;
    uint256 public _daoReserves = 0;
    uint256 public numTokensSellToAddToLiquidity = 10000 * 10**_decimals;
    uint256 public numTokensSellToAddToETH = 5000 * 10**_decimals;

    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public isLiquidityPair;

    event PrimaryRouterPairUpdated(address _router, address _pair);
    event AddedLiquidityPair(address _pair, bool _status);
    event ExcludedFromFeeUpdated(address _address, bool _status);
    event TaxAmountsUpdated(uint _liquidity, uint _dao);
    event DaoWalletUpdated(address _address);
    event SwapThresholdsChanged(uint _lpSwapThreshold, uint _daoSwapThreshold);
    event DaoTransferFailed(address _daoWallet, uint _amount);
    event SlippageLimitUpdated(uint _allowedSlippage);
    
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair;
    
    bool inSwapAndLiquify;

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    modifier lockTheSwap() {
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    constructor(address _router, address _daoWallet) ERC20(_name, _symbol) {
        require(_router != DEAD && _router != address(0), "Router cannot be the Dead address, or 0!");
        require(_daoWallet != DEAD && _daoWallet != address(0), "DAO Wallet cannot be the Dead address, or 0!");
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(_router);
        uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());
        
        uniswapV2Router = _uniswapV2Router;
        _approve(address(this), address(uniswapV2Router), type(uint256).max);
        daoWallet = address(_daoWallet);

        isExcludedFromFee[address(uniswapV2Router)] = true;
        isExcludedFromFee[msg.sender] = true;
        isExcludedFromFee[daoWallet] = true;
        isLiquidityPair[uniswapV2Pair] = true;
        
        _mint(msg.sender, 1_000_000_000 * 10**_decimals); //existing supply for token conversions
        _mint(daoWallet, 400_000_000 * 10**_decimals); //new supply for DAO ownership
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(balanceOf(from) >= amount, "ERC20: transfer amount exceeds balance");

        bool _isSendingDaoTokens = false;

        if ((isLiquidityPair[from] || isLiquidityPair[to]) 
        && taxForDao + taxForLiquidity > 0 
        && !inSwapAndLiquify) {
            if (!isLiquidityPair[from]) {
                uint256 contractLiquidityBalance = balanceOf(address(this)) - _daoReserves;
                if (contractLiquidityBalance >= numTokensSellToAddToLiquidity) {
                    _swapAndLiquify(numTokensSellToAddToLiquidity);
                }
                if (_daoReserves >= numTokensSellToAddToETH) {
                    _swapTokensForEth(numTokensSellToAddToETH);
                    _daoReserves -= numTokensSellToAddToETH;
                    _isSendingDaoTokens = true;
                }
            }

            uint256 transferAmount;
            if (isExcludedFromFee[from] || isExcludedFromFee[to]) {
                transferAmount = amount;
            }
            else {
                uint256 daoShare = ((amount * taxForDao) / 100);
                uint256 liquidityShare = ((amount * taxForLiquidity) / 100);
                transferAmount = amount - (daoShare + liquidityShare);
                _daoReserves += daoShare;

                super._transfer(from, address(this), (daoShare + liquidityShare));
            }
            super._transfer(from, to, transferAmount);
        } 
        else {
            super._transfer(from, to, amount);
        }

        if (_isSendingDaoTokens) {
            (bool success, ) = payable(daoWallet).call{value: address(this).balance}("");
            if(!success) {
                emit DaoTransferFailed(daoWallet, address(this).balance);
            }
        }
    }

    function _swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        uint256 half = (contractTokenBalance / 2);
        uint256 otherHalf = (contractTokenBalance - half);

        uint256 initialBalance = address(this).balance;

        _swapTokensForEth(half);

        uint256 newBalance = (address(this).balance - initialBalance);

        _addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function _swapTokensForEth(uint256 tokenAmount) private lockTheSwap {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        uint256 minEthOut = calculateMinimumETHFromTokenSwap(tokenAmount);
        
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            minEthOut,
            path,
            address(this),
            block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private lockTheSwap {
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            daoWallet,
            block.timestamp
        );
    }

    function burn(uint256 amount) external {
        require(amount > 0, "Cannot burn 0 tokens!");
        _burn(msg.sender, amount);
    }

    function updateRouter(address _router) external onlyOwner withTimelock("updateRouterPair") {
        require(_router != DEAD && _router != address(0), "Router cannot be the Dead address, or 0!");

        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(_router);
        address _pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .getPair(address(this), _uniswapV2Router.WETH());

        require(_pair != DEAD && _pair != address(0), "Pair cannot be the Dead address, or 0!");

        uniswapV2Pair = _pair;
        uniswapV2Router = _uniswapV2Router;

        isExcludedFromFee[address(uniswapV2Router)] = true;
        isLiquidityPair[uniswapV2Pair] = true;

        _approve(address(this), address(uniswapV2Router), type(uint256).max);
        emit PrimaryRouterPairUpdated(_router, _pair);
    }

    function changeDaoWallet(address newWallet) external onlyOwner
    {
        require(newWallet != DEAD && newWallet != address(0), "DAO Wallet cannot be the Dead address, or 0!");
        daoWallet = newWallet;
        emit DaoWalletUpdated(daoWallet);
    }

    function changeTaxForLiquidityAndDao(uint256 _taxForLiquidity, uint256 _taxForDao) 
        external
        onlyOwner
        withTimelock("changeTaxForLiquidityAndDao")
    {
        require((_taxForLiquidity+_taxForDao) <= 6, "ERC20: total tax must not be greater than 6%");
        taxForLiquidity = _taxForLiquidity;
        taxForDao = _taxForDao;
        emit TaxAmountsUpdated(taxForLiquidity, taxForDao);
    }

    function changeSwapThresholds(uint256 _numTokensSellToAddToLiquidity, uint256 _numTokensSellToAddToETH)
        external
        onlyOwner
    {
        require(_numTokensSellToAddToLiquidity < totalSupply() / 100, "Cannot liquidate more than 1% of the supply at once!");
        require(_numTokensSellToAddToETH < totalSupply() / 100, "Cannot liquidate more than 1% of the supply at once!");
        require(_numTokensSellToAddToLiquidity > 0, "LP: Must liquidate at least 1 token.");
        require(_numTokensSellToAddToETH > 0, "ETH/Gas Token: Must liquidate at least 1 token.");
        numTokensSellToAddToLiquidity = _numTokensSellToAddToLiquidity * 10**_decimals;
        numTokensSellToAddToETH = _numTokensSellToAddToETH * 10**_decimals;
        emit SwapThresholdsChanged(numTokensSellToAddToLiquidity, numTokensSellToAddToETH);
    }

    function updatePairStatus(address _pair, bool _status) external onlyOwner {
        require(isContract(_pair), "Address must be a contract");
        isLiquidityPair[_pair] = _status;
        emit AddedLiquidityPair(_pair, _status);
    }

    function excludeFromFee(address _address, bool _status) external onlyOwner {
        isExcludedFromFee[_address] = _status;
        emit ExcludedFromFeeUpdated(_address, _status);
    }

    function disableSlippageLimit() external onlyOwner {
        allowedSlippage = 0;
        emit SlippageLimitUpdated(allowedSlippage);
    }

    function setSlippageLimit(uint256 _allowedSlippage) external onlyOwner withTimelock("setSlippageLimit") {
        require(_allowedSlippage > 0 && _allowedSlippage <= 99, "Slippage limit must be between 1% and 99%");
        allowedSlippage = _allowedSlippage;
        emit SlippageLimitUpdated(allowedSlippage);
    }

    function calculateMinimumETHFromTokenSwap(uint256 tokenAmount) public view returns (uint256) {
        if (allowedSlippage == 0) {
            return 0;
        }

        require(uniswapV2Pair != address(0), "Token-ETH pair does not exist");

        IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Pair);
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();

        uint256 tokenReserve;
        uint256 ethReserve;
        if (pair.token0() == address(this)) {
            tokenReserve = reserve0;
            ethReserve = reserve1;
        } else {
            tokenReserve = reserve1;
            ethReserve = reserve0;
        }

        uint256 ethOut = uniswapV2Router.getAmountOut(tokenAmount, tokenReserve, ethReserve);
        uint256 minEthOut = (ethOut * (1000 - allowedSlippage)) / 1000;

        return minEthOut;
    }

    function isContract(address _addr) internal view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(_addr)
        }
        return (size > 0);
    }

    receive() external payable {}
}