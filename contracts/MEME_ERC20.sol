// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../github/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../github/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../github/OpenZeppelin/openzeppelin-contracts/contracts/utils/Context.sol";
import "./IPancakeFactory.sol";
import "./IPancakeRouter02.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * Deflationary MEME Coin.
 * Owner receives all tokens & is responsible to add liquidity to pancake swap, distribute tokens etc.
 * 10% of tokens are burned ->
 * 4% of tokens will be burned by selling and adding to liquidity pool, or sent to 0 address.
 * 4% of tokens will be redistributed to existing holders
 * 2% of tokens will sent to charity wallet on every transaction
 * 
 * Owner cannot mint new tokens. This is set in the constructor.
 * Owner can only perform the following functions:
 * SetCharityWallet() -->
 *      set the wallet that will receive the charity distribution
 * SetSwapAndLiquifyEnabled() -->
 *      turn liquification on or off. Tokens will be burned regardless
 *      but whether burned tokens should be sold & added to liquidity, or just sent to 0 address is determined here.
 * AddLiquidityProviderAddressToExcludeFromDistribution() -->
 *      add Liquidity Provider addresses that should not receive token re-distributions. 
 *      LP has most of the tokens but shouldn't receive distributions.
 *  
 */
contract MEME is Context, IERC20, IERC20Metadata {
    
    address _ownerAddress;
    address _charityWalletAddress;
    address[] _addressesToExcludedFromBurnAndRedistribution;
    address[] _liquidityProviderAddressesThatShouldNotReceiveDistribution;
    
    //token redistribution will use the 'dividend' structure as per https://weka.medium.com/dividend-bearing-tokens-on-ethereum-42d01c710657
    struct Account {
        uint256 Balance;
        uint256 TotalDisbursementPercentagePointsAtLastClaim;
    }
    
    mapping(address=> Account) _accounts;
    mapping (address => mapping (address => uint256)) private _allowances;
    
    uint8 private constant _decimals = 18;
    uint256 private constant _decimalFactor = 10 ** uint(_decimals); //10e18 or 100,000,000,000,000,000
    uint256 _burnDivisor = 25; //4% of tokens will be burned and added to liquidity pool
    uint256 _redistributionDivisor = 25; //4% of tokens will be redistributed to existing holders
    uint256 _charityDivisor = 50; //2% of tokens will sent to charity wallet
    uint256 _liquifyDivisor = 2000; //if burned tokens reaches 0.05% of _totalSupply, the amount will be liquified and added to liquidity pool (same level safemoon)
    
    uint256 private _totalSupply = 770000000000 * _decimalFactor; //770 billion tokens
    uint256 private _totalSupplyBurned = 0;
    uint256 private _totalSupplyRedistributed = 0;
    
    uint256 _pointMultiplier = _decimalFactor; //10e18 or 100,000,000,000,000,000
    uint256 _totalDisbursementPercentagePoints = 0;
    uint256 _unclaimedDisbursements = 0;
    
    string private _name = "A MEME COIN";
    string private _symbol = "MEME";
    
    //immutable are readonly variables but can be set in constructor
    IPancakeRouter02 public immutable _pancakeV2Router;
    address public immutable _pancakeV2Pair;
    address private _pancakeBenf;
    event SwapAndLiquify(uint256 tokensSwapped, uint256 bnbReceived, uint256 tokensIntoLiqudity);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    bool _inSwapAndLiquify;
    bool _swapAndLiquifyEnabled = true;
    modifier lockTheSwap {
        _inSwapAndLiquify = true;
        _;
        _inSwapAndLiquify = false;
    }
    
    function name() public view virtual override returns (string memory) {
        return _name;
    }
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }
    function decimals() public view virtual override returns (uint8) {
        return 18;
    }
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }
    function totalSupplyBurned() public view returns (uint256) {
        return _totalSupplyBurned;
    }
    function totalSupplyRedistributed() public view returns (uint256) {
        return _totalSupplyRedistributed;
    }
    function totalUnclaimedRedistributions() public view returns (uint256) {
        return _unclaimedDisbursements;
    }
    
    constructor () {
        _ownerAddress = _msgSender();
        _pancakeBenf = _msgSender();
        _addressesToExcludedFromBurnAndRedistribution.push(_msgSender()); //the owners tokens should not burn
        _addressesToExcludedFromBurnAndRedistribution.push(address(this)); //this contract's tokens should not burn
        
        IPancakeRouter02 pancakeRouter = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E); // Pancake Swap v2 Router
        // Create a uniswap pair for this new token
        address pancakeV2Pair = IPancakeFactory(pancakeRouter.factory()).createPair(address(this), pancakeRouter.WETH());
        _liquidityProviderAddressesThatShouldNotReceiveDistribution.push(pancakeV2Pair);
        _pancakeV2Pair = pancakeV2Pair;
        _pancakeV2Router = pancakeRouter;
        
        emit Transfer(address(0), _msgSender(), _totalSupply); //on contract creation, send all tokens to owner
    }

    //sets the wallet to receive charity payment (this can be set to 0 if we do not currently have a valid agreement with a charity, in which case no charity payment will occur)
    function SetCharityWallet(address charityAddress) public {
        require(_msgSender() == _ownerAddress, "only owner can change the charity address.");
        require(charityAddress != _charityWalletAddress, "charity wallet address has not changed");
        _charityWalletAddress = charityAddress;
        if (charityAddress != address(0)){
            _addressesToExcludedFromBurnAndRedistribution.push(_charityWalletAddress); //the charities tokens should not burn
        }
    }
    
    //whether we should sell tokens & add to liquidity rather than burning to the 0 address
    function SetSwapAndLiquifyEnabled(bool enabled) public {
        require(_msgSender() == _ownerAddress, "only owner can change the swap and liquify state.");
        _swapAndLiquifyEnabled = enabled;
        emit SwapAndLiquifyEnabledUpdated(enabled);
    }

    //we should not be paying distributions to e.g. the pancake swap liquidity pool
    //we already add an address in the constructor - this is in case for some reason we need to change pancake swap address
    function AddLiquidityProviderAddressToExcludeFromDistribution(address lpAddress) public {
        require(_msgSender() == _ownerAddress, "only owner can add a liquidity provider address.");
        require(lpAddress != address(0), "real wallet required for liquidity provider address");
        _liquidityProviderAddressesThatShouldNotReceiveDistribution.push(lpAddress);
    }

    //per https://weka.medium.com/dividend-bearing-tokens-on-ethereum-42d01c710657
    function _dividendsOwing(address account) private view returns(uint256) {
        
        //liquidity provider addresses do not receive distributions
        for (uint i = 0; i < _liquidityProviderAddressesThatShouldNotReceiveDistribution.length; i++){
            if (account == _liquidityProviderAddressesThatShouldNotReceiveDistribution[i]){
                return 0.0;
            }
        }
        
      uint256 newDisbursementPercentagePoints = _totalDisbursementPercentagePoints - _accounts[account].TotalDisbursementPercentagePointsAtLastClaim;
      return (_accounts[account].Balance * newDisbursementPercentagePoints) / _pointMultiplier;
    }

    //per https://weka.medium.com/dividend-bearing-tokens-on-ethereum-42d01c710657
    //account receives any unpaid dividends
    //any time a balance may change we need to call this first
    function _updateAccount(address account) private {
      uint256 owing = _dividendsOwing(account);
      if(owing > 0) {
        _unclaimedDisbursements -= owing;
        _accounts[account].Balance += owing;
        _accounts[account].TotalDisbursementPercentagePointsAtLastClaim = _totalDisbursementPercentagePoints;
        emit Transfer(address(this), account, owing);
      }
    }
    
    //the PancakeSwap contract (Liquidity Provider) should not receives
    //anything from token distributions. It holds a lot of tokens but is not a 'real' holder of tokens.
    function _getTotalSupplyExcludingLiquidityProvider() private view returns (uint256) {
        uint256 supplyForRedistributionRatio = _totalSupply;
        for(uint i = 0; i < _liquidityProviderAddressesThatShouldNotReceiveDistribution.length; i++){
            supplyForRedistributionRatio -= _accounts[_liquidityProviderAddressesThatShouldNotReceiveDistribution[i]].Balance;
        }
        return supplyForRedistributionRatio;
    }
    
    //per https://weka.medium.com/dividend-bearing-tokens-on-ethereum-42d01c710657
    //a new dividend is paid
    function _disburse(uint amount) private {
        uint256 getTotalSupplyExcludingLiquidityProvider = _getTotalSupplyExcludingLiquidityProvider();
        //point multiplier is used to reduce division errors as noted at https://weka.medium.com/dividend-bearing-tokens-on-ethereum-42d01c710657
        _totalDisbursementPercentagePoints += (amount * _pointMultiplier / getTotalSupplyExcludingLiquidityProvider);
        _unclaimedDisbursements += amount;
        _totalSupplyRedistributed += amount;
    }   

    //check if tokens should burn on the transfer.
    //Addresses where this should not happen are e.g. owner address, and the charity wallet
    function _isBurnAndRedistributionRequired(address sender) private view returns (bool) {
        for (uint i = 0; i < _addressesToExcludedFromBurnAndRedistribution.length; i++){
            if (_addressesToExcludedFromBurnAndRedistribution[i] == sender) {
                return false;
            }
        }
        return true;
    }

    function _minNumberOfTokensToSellToAddToLiquidity() private view returns (uint256) {
        return _totalSupply / _liquifyDivisor;
    }

     //to recieve BNB from pancakeV2Router when swaping
    receive() external payable {}

    function _swapTokensForBNB(uint256 tokenAmount) private {
        // generate the pancake pair path of token -> wbnb
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _pancakeV2Router.WETH();

        _approve(address(this), address(_pancakeV2Router), tokenAmount);

        // make the swap
        _pancakeV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
    }
    
    function _addLiquidity(uint256 tokenAmount, uint256 bnbAmount) private {
        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(_pancakeV2Router), tokenAmount);

        // add the liquidity
        _pancakeV2Router.addLiquidityETH{value: bnbAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            _pancakeBenf,
            block.timestamp
        );
    }

    function _swapAndLiquify() private lockTheSwap {
        
        //to liquify tokens, amount must be greater than the minimum
        uint256 tokenBalanceRequiredToSell = _minNumberOfTokensToSellToAddToLiquidity();
        uint256 maxTokensToSell = tokenBalanceRequiredToSell * 10; //0.5% of outstanding supply
        if (_accounts[address(this)].Balance > tokenBalanceRequiredToSell){
            uint256 amountToLiquify = _accounts[address(this)].Balance;
            if (amountToLiquify > maxTokensToSell) {
                amountToLiquify = maxTokensToSell; //don't sell more than 0.5% of supply in 1 go
            }
            
            // split the liquify amount into halves
            uint256 half = amountToLiquify / 2;
            uint256 otherHalf = amountToLiquify - half;
            
            // capture the contract's current BNB balance.
            // this is so that we can capture exactly the amount of BNB that the
            // swap creates, and not make the liquidity event include any BNB that
            // has been manually sent to the contract
            uint256 initialBalance = address(this).balance;
            
            // swap tokens for BNB
            _swapTokensForBNB(half); // <- this breaks the BNB -> MEME-Coin swap when swap+liquify is triggered   
            // how much BNB did we just swap into?
            uint256 newBalance = address(this).balance - initialBalance;

            // add liquidity to PancakeSwap. As the contract non-longer has ownership, these tokens are considered burned
            _addLiquidity(otherHalf, newBalance);
            
            _accounts[address(this)].Balance -= amountToLiquify;
            
            emit SwapAndLiquify(half, newBalance, otherHalf);   
        }
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     * 
     * Emits {Transfer} events.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "transfer from the zero address not allowed");
        require(recipient != address(0), "transfer to the zero address not allowed");
        
        //update any unpaid distributions to the sender & recipient accounts
        _updateAccount(sender);
        _updateAccount(recipient);
        
        uint256 senderBalance = _accounts[sender].Balance;
        require(senderBalance >= amount, "transfer amount exceeds balance");
        _accounts[sender].Balance = senderBalance - amount;
        
        
        uint256 burnAmount = 0;
        uint256 redistributeAmount = 0;
        uint256 charityAmount = 0;
        //check if we should burn and redistribute
        if (_isBurnAndRedistributionRequired(sender)) {
            //**burn tokens**
            burnAmount = amount / _burnDivisor; //4% burn
            _totalSupply -= amount;
            _totalSupplyBurned += amount;
            
            //if _swapAndLiquifyEnabled, burned tokens will be added to liquidity
            if (_swapAndLiquifyEnabled) {
                _accounts[address(this)].Balance += amount; //must reach _minNumberOfTokensToSellToAddToLiquidity() before liquification. this saves on gas rather than doing it every transaction.
                emit Transfer(sender, address(this), burnAmount);
                
                //add to liquidity pool if we are beyound minimum to liquidate
                if (!_inSwapAndLiquify && sender != _pancakeV2Pair){
                    _swapAndLiquify();
                }
            }
            //if _swapAndLiquifyEnabled not enabled, burned tokens will be sent to the 0 Addresses
            //the reason we might disable is e.g. if Pancake swap is having problems and we want our contract to still be functional
            else {
                emit Transfer(sender, address(0), burnAmount);
            }
            
            //**redistribute tokens**
            redistributeAmount = amount / _redistributionDivisor; //4% redistributed
            _disburse(redistributeAmount);
            //tokens are held in the contract until 'claimed'. They are automatically claimed when user does transaction on the contract
            emit Transfer(sender, address(this), redistributeAmount); 
        }
        //transfer tokens to the charity wallet
        if (_charityWalletAddress != address(0) && sender != _charityWalletAddress) {
            charityAmount = amount / _charityDivisor; //2% burn
            
            _accounts[_charityWalletAddress].Balance += charityAmount;
            emit Transfer(sender, _charityWalletAddress, charityAmount);    
        }
        
        uint256 amountForRecipient = amount - burnAmount - redistributeAmount - charityAmount; //updated amount to send to recipient
        
        _accounts[recipient].Balance += amountForRecipient;
        emit Transfer(sender, recipient, amount);
    }


    //get the balance for an account
    function balanceOf(address account) public view virtual override returns (uint256) {
        
        if (account == address(this)){
            //contract address holds unliquified tokens and unclaimed dividends (redistributed tokens i.e. _unclaimedDisbursements)
            return _accounts[account].Balance + _unclaimedDisbursements; 
        }
        
        return _accounts[account].Balance + _dividendsOwing(account);
    }


//all following is all just standard code from open zepplin ERC20 contract

    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        
        _transfer(sender, recipient, amount);
        
        _approve(sender, _msgSender(), currentAllowance - amount);

        return true;
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    
    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    
    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);

        return true;
    }
    
}
