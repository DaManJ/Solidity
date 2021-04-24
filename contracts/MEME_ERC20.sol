// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../github/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "../github/OpenZeppelin/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../github/OpenZeppelin/openzeppelin-contracts/contracts/utils/Context.sol";

/**
 * @dev Implementation of the {IERC20} interface.
 *
 * This implementation is agnostic to the way tokens are created. This means
 * that a supply mechanism has to be added in a derived contract using {_mint}.
 * For a generic mechanism see {ERC20PresetMinterPauser}.
 *
 * TIP: For a detailed writeup see our guide
 * https://forum.zeppelin.solutions/t/how-to-implement-erc20-supply-mechanisms/226[How
 * to implement supply mechanisms].
 *
 * We have followed general OpenZeppelin guidelines: functions revert instead
 * of returning `false` on failure. This behavior is nonetheless conventional
 * and does not conflict with the expectations of ERC20 applications.
 *
 * Additionally, an {Approval} event is emitted on calls to {transferFrom}.
 * This allows applications to reconstruct the allowance for all accounts just
 * by listening to said events. Other implementations of the EIP may not emit
 * these events, as it isn't required by the specification.
 *
 * Finally, the non-standard {decreaseAllowance} and {increaseAllowance}
 * functions have been added to mitigate the well-known issues around setting
 * allowances. See {IERC20-approve}.
 */
contract MEME is Context, IERC20, IERC20Metadata {
    
    address _ownerAddress;
    address _charityWalletAddress;
    uint256 _charityBalance;
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
    uint256 private constant _decimalFactor = 10 ** uint(_decimals);
    uint256 _burnDivisor = 25; //4% of tokens will be burned on every transaction
    uint256 _redistributionDivisor = 25; //4% of tokens will sent to charity wallet on every transaction
    uint256 _charityDivisor = 50; //2% of tokens will sent to charity wallet on every transaction
    
    uint256 private _totalSupply = 770000000000 * _decimalFactor; //770 billion tokens
    uint256 private _totalSupplyBurned = 0;
    uint256 private _totalSupplyRedistributed = 0;
    
    uint256 _pointMultiplier = 10e18;
    uint256 _totalDisbursementPercentagePoints = 0;
    uint256 _unclaimedDisbursements = 0;
    
    string private _name = "MEME";
    string private _symbol = "MEME";
    
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
        _addressesToExcludedFromBurnAndRedistribution.push(_msgSender()); //the owners tokens should not burn
        emit Transfer(address(0), _msgSender(), _totalSupply); //on contract creation, send all tokens to owner
    }

    function SetCharityWallet(address charityAddress) public {
        require(_msgSender() == _ownerAddress, "only owner can change the charity address.");
        require(charityAddress != address(0), "real wallet required for charity address");
        require(charityAddress != _charityWalletAddress, "charity wallet address has not changed");
        _charityWalletAddress = charityAddress;
        _addressesToExcludedFromBurnAndRedistribution.push(_charityWalletAddress); //the charities tokens should not burn
    }

    function AddLiquidityProviderAddressToExcludeFromDistribution(address lpAddress) public {
        require(_msgSender() == _ownerAddress, "only owner can add a liquidity provider address.");
        require(lpAddress != address(0), "real wallet required for liquidity provider address");
        _liquidityProviderAddressesThatShouldNotReceiveDistribution.push(lpAddress); //the charities tokens should not burn
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
        _totalDisbursementPercentagePoints += (amount * _pointMultiplier / getTotalSupplyExcludingLiquidityProvider);
        _unclaimedDisbursements += amount;
        _totalSupplyRedistributed += amount;
    }   

    //check if tokens should burn on the transfer
    function _isBurnAndRedistributionRequired(address sender) private view returns (bool) {
        for (uint i = 0; i < _addressesToExcludedFromBurnAndRedistribution.length; i++){
            if (_addressesToExcludedFromBurnAndRedistribution[i] == sender) {
                return false;
            }
        }
        return true;
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
            emit Transfer(sender, address(0), burnAmount);
            
            //**redistribute tokens**
            redistributeAmount = amount / _redistributionDivisor; //4% redistributed
            _disburse(redistributeAmount);
        }
        //check if we can transfer the charity tokens
        if (_charityWalletAddress != address(0) && sender != _charityWalletAddress) {
            charityAmount = amount / _charityDivisor; //2% burn
            emit Transfer(sender, _charityWalletAddress, charityAmount);    
        }
        
        uint256 amountForRecipient = amount - burnAmount - redistributeAmount - charityAmount; //updated amount to send to recipient
        
        _accounts[recipient].Balance += amountForRecipient;
        emit Transfer(sender, recipient, amount);
    }


    //get the balance for an account
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _accounts[account].Balance + _dividendsOwing(account);
    }

    
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