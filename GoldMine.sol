pragma solidity 0.4.25;

import 'openzeppelin-solidity/contracts/math/SafeMath.sol';
import 'openzeppelin-solidity/contracts/ownership/Ownable.sol';

contract GoldMine is Ownable {
  using SafeMath for uint;

  /*=================================
  =            MODIFIERS            =
  =================================*/

  modifier onlyHolders() {
    require(getMyFrontEndTokens() > 0);
    _;
  }

  modifier onlyDividendHolder() {
    require(getMyDividends(true) > 0);
    _;
  }

  modifier onlyAdministrator() {
      address _customerAddress = msg.sender;
      require(administrators[keccak256(_customerAddress)]);
      _;
  }

  modifier onlySellingPhase() {
    require(sellingPhase);
    _;
  }

  modifier onlyValidDividendRate(uint8 _divRate) {
    require(validDividendRates_[_divRate]);
    _;
  }

  /*=================================
  =             EVENTS              =
  =================================*/

  event onTokenPurchase(
    address indexed customerAddress,
    uint incomingEthereum,
    uint tokensMinted,
    address indexed referredBy
  );

  event UserDividendRate(
    address user,
    uint divRate
  );

  event onTokenSell(
    address indexed customerAddress,
    uint tokensBurned,
    uint ethereumEarned
  );

  event onReinvestment(
    address indexed customerAddress,
    uint ethereumReinvested,
    uint tokensMinted
  );

  event onWithdraw(
    address indexed customerAddress,
    uint ethereumWithdrawn
  );

  event Transfer(
    address indexed from,
    address indexed to,
    uint tokens
  );

  event Approval(
    address indexed tokenOwner,
    address indexed spender,
    uint tokens
  );

  event Allocation(
    uint toReferrer,
    uint toTokenHolders,
    uint toBuyer,
    uint toBuyerInTokens
  );

  event Referral(
    address referrer,
    uint amountReceived
  );

  event DevFund(
    uint amountReceived
  );

  /*=================================
  =           CONFIGURABLES         =
  =================================*/

  string public name = "GoldMine";
  string public symbol = "GOLD";

  address internal devFundAddress; 

  /*=================================
  =            CONSTANTS            =
  =================================*/

  uint8 constant public  decimals = 18;

  // Initial Token Price 
  uint constant internal tokenPriceInitial_     = 0.000001 ether;
  uint constant internal tokenPriceIncremental_ = 0.0000001 ether;

  uint constant internal magnitude = 2**64;


  // Pre-launch preferences 
  uint constant internal icoHardCap = 100 ether;
  uint constant internal addressICOLimit = 1 ether;
  uint constant internal icoMinBuyIn = 0.1 finney;

  uint constant internal MULTIPLIER = 9615;

  uint constant internal MIN_ETH_BUYIN = 0.0001 ether;
  uint constant internal MIN_TOKEN_SELL_AMOUNT = 0.0001 ether;
  uint constant internal MIN_TOKEN_TRANSFER = 1e10;
  uint constant internal referrer_percentage = 25;
  uint constant internal dev_percentage = 10;
  uint8 constant internal DEFAULT_DIVIDEND_RATE = 20;

  uint public stakingRequirement = 100e18;


  //Bankroll
  address internal bankrollAddress;

  /*=================================
  =            DATASET              =
  =================================*/

  // Phases
  bool public sellingPhase = false;
  bool public icoPhase = false;

  // Admins & Ambassadors
  mapping(bytes32 => bool) internal administrators;
  mapping(bytes32 => bool) internal ambassadors;
  address[] public tokenHolders;

  // Track front-end token & dividend token
  mapping(address => uint) internal frontTokenBalanceLedger_;
  mapping(address => uint) internal dividendTokenBalanceLedger_;
  mapping(address => mapping (address => uint)) public allowed;

  // Tracks dividend rates for users
  mapping(uint8   => bool) internal validDividendRates_;
  mapping(address => bool) internal userSelectedRate;
  mapping(address => uint8) internal userDividendRate;

  // Payout tracking
  mapping(address => uint) internal referralBalance_;
  mapping(address => int256) internal payoutsTo_;

  // ICO per-address limit tracking
  mapping(address => uint) internal ICOBuyIn;


  // Token Supply
  uint internal tokenSupply    = 0;
  uint internal divTokenSupply = 0;

  uint public tokensMintedDuringICO;
  uint public ethInvestedDuringICO;

  uint public currentEthInvested;
  uint internal profitPerDivToken;

  /*=================================
  =           INTERFACES            =
  =================================*/

  constructor (address _bankrollAddress)
  public
  {
    // Set Bankroll
    bankrollAddress = _bankrollAddress;
    userSelectedRate[bankrollAddress] = true;
    userDividendRate[bankrollAddress] = 33;

    // Set administrator addresses
    // administrators[msg.sender] = true;
    // administrators[0x4F4eBF556CFDc21c3424F85ff6572C77c514Fcae] = true;

    // Set ambassador addresses 
    // ambassados[0x4F4eBF556CFDc21c3424F85ff6572C77c514Fcae] =  true;

    // Set dividend rates
    validDividendRates_[0] = true;
    validDividendRates_[2] = true;
    validDividendRates_[20] = true;
    validDividendRates_[33] = true;
  }

  /**
    TODO : check commit : buyAndSetDividendPercentage()
   */
  function buyAndSetDividendPercentage(address _referredBy, uint8 _divChoice)
  public
  payable
  onlySellingPhase
  onlyValidDividendRate(_divChoice)
  returns (uint)
  {
    address _customerAddress = msg.sender;
    userSelectedRate[_customerAddress] = true;
    userDividendRate[_customerAddress] = _divChoice;

    purchaseTokens(msg.value,_referredBy);
  }

  function buy(address _referredBy)
  public
  payable
  onlySellingPhase
  returns(uint)
  {
    address _customerAddress = msg.sender;
    require (userSelectedRate[_customerAddress]);
    purchaseTokens(msg.value, _referredBy);
  }

  function buyAndTransfer(address _referredBy, address _target, uint8 _divChoice)
  public
  payable
  onlySellingPhase
  onlyValidDividendRate(_divChoice)
  {
    address _customerAddress = msg.sender;
    uint256 _frontendBalance = frontTokenBalanceLedger_[_customerAddress];

    if (userSelectedRate[_customerAddress]) {
      purchaseTokens(msg.value, _referredBy);
    } else {
      buyAndSetDividendPercentage(_referredBy, _divChoice);
    }
    uint256 _difference = SafeMath.sub(frontTokenBalanceLedger_[msg.sender], _frontendBalance);
    transfer(_target, _difference);
  }

  function reinvest()
  public
  onlyDividendHolder
  onlySellingPhase
  {
    uint _dividends = getMyDividends(false);

    // Pay out requisite `virtual' dividends.
    address _customerAddress            = msg.sender;
    payoutsTo_[_customerAddress]       += (int256) (_dividends * magnitude);

    _dividends                         += referralBalance_[_customerAddress];
    referralBalance_[_customerAddress]  = 0;

    uint _tokens                        = purchaseTokens(_dividends, 0x0);

    // Fire logging event.
    emit onReinvestment(_customerAddress, _dividends, _tokens);
  }

  function exit()
  public
  onlySellingPhase
  {
    // Retrieve token balance for caller, then sell them all.
    address _customerAddress = msg.sender;
    uint _tokens             = frontTokenBalanceLedger_[_customerAddress];

    if(_tokens > 0) sell(_tokens);

    withdraw(_customerAddress);
  }

  function withdraw(address _recipient)
  public
  onlyDividendHolder
  onlySellingPhase
  {
    // Setup data
    address _customerAddress           = msg.sender;
    uint _dividends                    = getMyDividends(false);

    // update dividend tracker
    payoutsTo_[_customerAddress]       +=  (int256) (_dividends * magnitude);

    // add ref. bonus
    _dividends                         += referralBalance_[_customerAddress];
    referralBalance_[_customerAddress]  = 0;

    if (_recipient == address(0x0)){
      _recipient = msg.sender;
    }
    _recipient.transfer(_dividends);

    // Fire logging event.
    emit onWithdraw(_recipient, _dividends);
  }

  // Sells front-end tokens.
  // Logic concerning step-pricing of tokens pre/post-ICO is encapsulated in tokensToEthereum_.
  function sell(uint _amountOfTokens)
  public
  onlyHolders
  onlySellingPhase
  {
    require(_amountOfTokens <= frontTokenBalanceLedger_[msg.sender]);

    uint _frontEndTokensToBurn = _amountOfTokens;

    // Calculate how many dividend tokens this action burns.
    // Computed as the caller's average dividend rate multiplied by the number of front-end tokens held.
    // As an additional guard, we ensure that the dividend rate is between 2 and 50 inclusive.
    uint userDivRate  = getUserAverageDividendRate(msg.sender);
    require ((2*magnitude) <= userDivRate && (50*magnitude) >= userDivRate );
    uint _divTokensToBurn = (_frontEndTokensToBurn.mul(userDivRate)).div(magnitude);

    // Calculate ethereum received before dividends
    uint _ethereum = tokensToEthereum_(_frontEndTokensToBurn);

    if (_ethereum > currentEthInvested){
      // Well, congratulations, you've emptied the coffers.
      currentEthInvested = 0;
    } else { currentEthInvested = currentEthInvested - _ethereum; }

    // Calculate dividends generated from the sale.
    uint _dividends = (_ethereum.mul(getUserAverageDividendRate(msg.sender)).div(100)).div(magnitude);

    // Calculate Ethereum receivable net of dividends.
    uint _taxedEthereum = _ethereum.sub(_dividends);

    // Burn the sold tokens (both front-end and back-end variants).
    tokenSupply         = tokenSupply.sub(_frontEndTokensToBurn);
    divTokenSupply      = divTokenSupply.sub(_divTokensToBurn);

    // Subtract the token balances for the seller
    frontTokenBalanceLedger_[msg.sender]    = frontTokenBalanceLedger_[msg.sender].sub(_frontEndTokensToBurn);
    dividendTokenBalanceLedger_[msg.sender] = dividendTokenBalanceLedger_[msg.sender].sub(_divTokensToBurn);

    // Update dividends tracker
    int256 _updatedPayouts  = (int256) (profitPerDivToken * _divTokensToBurn + (_taxedEthereum * magnitude));
    payoutsTo_[msg.sender] -= _updatedPayouts;

    // Let's avoid breaking arithmetic where we can, eh?
    if (divTokenSupply > 0) {
      // Update the value of each remaining back-end dividend token.
      profitPerDivToken = profitPerDivToken.add((_dividends * magnitude) / divTokenSupply);
    }

    // Fire logging event.
    emit onTokenSell(msg.sender, _frontEndTokensToBurn, _taxedEthereum);
  }

  /**
   * Transfer tokens from the caller to a new holder.
   * No charge incurred for the transfer. We'd make a terrible bank.
   */
  function transfer(address _toAddress, uint _amountOfTokens)
  public
  onlyHolders
  returns(bool)
  {
    require(_amountOfTokens >= MIN_TOKEN_TRANSFER
    && _amountOfTokens <= frontTokenBalanceLedger_[msg.sender]);
    transferFromInternal(msg.sender, _toAddress, _amountOfTokens);
    return true;

  }

  function approve(address spender, uint tokens)
  public
  returns (bool)
  {
    address _customerAddress           = msg.sender;
    allowed[_customerAddress][spender] = tokens;

    emit Approval(_customerAddress, spender, tokens);

    return true;
  }

  function totalSupply()
  public
  view
  returns (uint256)
  {
    return tokenSupply;
  }


  function()
  payable
  public
  {
    /**
    / If the user has previously set a dividend rate, sending
    /   Ether directly to the contract simply purchases more at
    /   the most recent rate. If this is their first time, they
    /   are automatically placed into the 20% rate `bucket'.
    **/
    require(sellingPhase);
    address _customerAddress = msg.sender;
    if (userSelectedRate[_customerAddress]) {
      purchaseTokens(msg.value, address(0));
    } else {
      buyAndSetDividendPercentage(address(0), DEFAULT_DIVIDEND_RATE);
    }
  }

  /*=================================
  =     ADMINISTRATION FUNCTIONS    =
  =================================*/

  function startICOPhase()
  public
  onlyAdministrator
  {
    icoPhase = true;
  }

  function endICOPhase()
  public
  onlyAdministrator
  {
    icoPhase = false;
  }

  function startSellingPhase()
  public
  onlyAdministrator
  {
    icoPhase = false;
    sellingPhase = true;
  }

  function setStakingRequirement(uint _amountOfTokens)
  public
  onlyAdministrator
  {
    require (_amountOfTokens >= 100e18);
    stakingRequirement = _amountOfTokens;
  }

  function setName(string _name)
  public
  onlyAdministrator
  {
    name = _name;
  }

  function setSymbol(string _symbol)
  public
  onlyAdministrator
  {
    symbol = _symbol;
  }

  /*=================================
  =             GETTERS             =
  =================================*/

  function totalEthereumBalance()
  public
  view
  returns(uint)
  {
    return address(this).balance;
  }

  function totalEthereumICOReceived()
  public
  view
  returns(uint)
  {
    return ethInvestedDuringICO;
  }

  /**
   * Retrieves your currently selected dividend rate.
   */
  function getMyDividendRate()
  public
  view
  returns(uint8)
  {
    address _customerAddress = msg.sender;
    require(userSelectedRate[_customerAddress]);
    return userDividendRate[_customerAddress];
  }

  /**
   * Retrieve the frontend tokens owned by the caller
   */
  function getMyFrontEndTokens()
  public
  view
  returns(uint)
  {
    address _customerAddress = msg.sender;
    return getFrontEndTokenBalanceOf(_customerAddress);
  }

  /**
   * Retrieve the dividend tokens owned by the caller
   */
  function getMyDividendTokens()
  public
  view
  returns(uint)
  {
    address _customerAddress = msg.sender;
    return getDividendTokenBalanceOf(_customerAddress);
  }

  /**
   * Retrieve the referral dividend tokens owned by the caller
   */
  function getMyReferralDividends()
  public
  view
  returns(uint)
  {
    address _customerAddress = msg.sender;
    return referralBalance_[_customerAddress]; 
  }

  function getMyDividends(bool _includeReferralBonus)
  public
  view
  returns(uint)
  {
    address _customerAddress = msg.sender;
    return _includeReferralBonus ? SafeMath.add(dividendsOf(_customerAddress), referralBalance_[_customerAddress]) : dividendsOf(_customerAddress) ;
  }

  function getMyAverageDividendRate() public view returns (uint) {
    return getUserAverageDividendRate(msg.sender);
  }

  function theDividendsOf(bool _includeReferralBonus, address _customerAddress)
  public
  view
  returns(uint)
  {
    return _includeReferralBonus ? SafeMath.add(dividendsOf(_customerAddress), referralBalance_[_customerAddress]) : dividendsOf(_customerAddress) ;
  }

  function getFrontEndTokenBalanceOf(address _customerAddress)
  view
  public
  returns(uint)
  {
    return frontTokenBalanceLedger_[_customerAddress];
  }

  function balanceOf(address _owner)
  view
  public
  returns(uint)
  {
    return getFrontEndTokenBalanceOf(_owner);
  }

  function getDividendTokenBalanceOf(address _customerAddress)
  view
  public
  returns(uint)
  {
    return dividendTokenBalanceLedger_[_customerAddress];
  }

  function dividendsOf(address _customerAddress)
  view
  public
  returns(uint)
  {
    return (uint) ((int256)(profitPerDivToken * dividendTokenBalanceLedger_[_customerAddress]) - payoutsTo_[_customerAddress]) / magnitude;
  }

  // Get the sell price at the user's average dividend rate
  function sellPrice()
  public
  view
  returns(uint)
  {
    uint price;

    if (icoPhase || currentEthInvested < ethInvestedDuringICO) {
      price = tokenPriceInitial_;
    } else {

      // Calculate the tokens received for 100 finney.
      // Divide to find the average, to calculate the price.
      uint tokensReceivedForEth = ethereumToTokens_(0.001 ether);

      price = (1e18 * 0.001 ether) / tokensReceivedForEth;
    }

    // Factor in the user's average dividend rate
    uint theSellPrice = price.sub((price.mul(getUserAverageDividendRate(msg.sender)).div(100)).div(magnitude));

    return theSellPrice;
  }

  // Get the buy price at a particular dividend rate
  function buyPrice(uint dividendRate)
  public
  view
  returns(uint)
  {
    uint price;

    if (icoPhase || currentEthInvested < ethInvestedDuringICO) {
      price = tokenPriceInitial_;
    } else {

      // Calculate the tokens received for 100 finney.
      // Divide to find the average, to calculate the price.
      uint tokensReceivedForEth = ethereumToTokens_(0.001 ether);

      price = (1e18 * 0.001 ether) / tokensReceivedForEth;
    }

    // Factor in the user's selected dividend rate
    uint theBuyPrice = (price.mul(dividendRate).div(100)).add(price);

    return theBuyPrice;
  }

  function buyPrice() 
  public 
  view 
  returns(uint256)
  {
    // our calculation relies on the token supply, so we need supply. Doh.
    if(tokenSupply == 0){
      return tokenPriceInitial_ + tokenPriceIncremental_;
    } else {
      uint256 _ethereum = tokensToEthereum_(1e18);
      return _ethereum;
    }
  }

  function calculateTokensReceived(uint _ethereumToSpend)
  public
  view
  returns(uint)
  {
    uint _dividends      = (_ethereumToSpend.mul(userDividendRate[msg.sender])).div(100);
    uint _taxedEthereum  = _ethereumToSpend.sub(_dividends);
    uint _amountOfTokens = ethereumToTokens_(_taxedEthereum);
    return  _amountOfTokens;
  }

  // When selling tokens, we need to calculate the user's current dividend rate.
  // This is different from their selected dividend rate.
  function calculateEthereumReceived(uint _tokensToSell)
  public
  view
  returns(uint)
  {
    require(_tokensToSell <= tokenSupply);
    uint _ethereum               = tokensToEthereum_(_tokensToSell);
    uint userAverageDividendRate = getUserAverageDividendRate(msg.sender);
    uint _dividends              = (_ethereum.mul(userAverageDividendRate).div(100)).div(magnitude);
    uint _taxedEthereum          = _ethereum.sub(_dividends);
    return  _taxedEthereum;
  }

  /*
   * Get's a user's average dividend rate - which is just their divTokenBalance / tokenBalance
   * We multiply by magnitude to avoid precision errors.
   */
  function getUserAverageDividendRate(address user) public view returns (uint) {
    return (magnitude * dividendTokenBalanceLedger_[user]).div(frontTokenBalanceLedger_[user]);
  }

  /*=================================
  =        INTERNAL FUNCTIONS       =
  =================================*/

  /* Purchase tokens with Ether.
    During ICO phase, dividends should go to the bankroll
    During normal operation:
      25% of dividends should go to the referrer, if any is provided. 
      10% of dividends should go to dev fund.
      The rest of dividends go to token holders.
  */
  function purchaseTokens(uint _incomingEthereum, address _referredBy)
  internal
  returns(uint)
  {
    require(_incomingEthereum >= MIN_ETH_BUYIN || msg.sender == bankrollAddress, "Tried to buy below the min eth buyin threshold.");

    uint toReferrer = 0;
    uint toDev = 0;
    uint toTokenHolders;

    uint dividendAmount;

    uint tokensBought;
    uint dividendTokensBought;

    uint remainingEth = _incomingEthereum;

    uint fee;

    /* Tax for dividends:
       Dividends = (ethereum * div%) / 100
    */

    // Grab the user's dividend rate
    uint dividendRate = userDividendRate[msg.sender];

    // Calculate the total dividends on this buy
    dividendAmount = (remainingEth.mul(dividendRate)).div(100);
    remainingEth = remainingEth.sub(dividendAmount);

    // Calculate how many tokens to buy:
    tokensBought = ethereumToTokens_(remainingEth);
    dividendTokensBought = tokensBought.mul(dividendRate);

    // This is where we actually mint tokens:
    tokenSupply = tokenSupply.add(tokensBought);
    divTokenSupply = divTokenSupply.add(dividendTokensBought);

    /* Update the total investment tracker
       Note that this must be done AFTER we calculate how many tokens are bought -
       because ethereumToTokens needs to know the amount *before* investment, not *after* investment. */

    currentEthInvested += remainingEth;

    // 10% goes to dev
    toDev = (dividendAmount.mul(dev_percentage)).div(100);
    if(toDev != 0) {
      emit DevFund(toDev);
      devFundAddress.transfer(toDev);
    }

    // 25% goes to referrers, if set
    if (_referredBy != address(0) &&
    _referredBy != msg.sender &&
    frontTokenBalanceLedger_[_referredBy] >= stakingRequirement)
    {
      toReferrer = (dividendAmount.mul(referrer_percentage)).div(100);
      referralBalance_[_referredBy] += toReferrer;
      emit Referral(_referredBy, toReferrer);
    }

    // The rest of the dividends go to token holders
    toTokenHolders = (dividendAmount.sub(toReferrer)).sub(toDev);

    // calculate the amount of tokens the customer receives over his purchase 
    fee = toTokenHolders * magnitude;
    fee = fee - (fee - (dividendTokensBought * (toTokenHolders * magnitude / (divTokenSupply))));

    // Finally, increase the divToken value
    profitPerDivToken       = profitPerDivToken.add((toTokenHolders.mul(magnitude)).div(divTokenSupply));
    //tokensBought -= (uint256) ((profitPerDivToken * dividendTokensBought) - fee);
    payoutsTo_[msg.sender] += (int256) ((profitPerDivToken * dividendTokensBought) - fee);

    // Update the buyer's token amounts
    frontTokenBalanceLedger_[msg.sender] = frontTokenBalanceLedger_[msg.sender].add(tokensBought);
    dividendTokenBalanceLedger_[msg.sender] = dividendTokenBalanceLedger_[msg.sender].add(dividendTokensBought);
    if(!userSelectedRate[msg.sender])
      tokenHolders.push(msg.sender);

    // This event should help us track where all the eth is going
    emit Allocation(toReferrer, toTokenHolders, remainingEth, tokensBought);

    // Sanity checking
    uint sum = toReferrer + toDev + toTokenHolders + remainingEth - _incomingEthereum;
    assert(sum == 0);
  }

  function ethereumToTokens_(uint256 _ethereum)
  internal
  view
  returns(uint256)
  {
    uint256 _tokenPriceInitial = tokenPriceInitial_ * 1e18;
    uint256 _tokensReceived = 
    (
      (
        // underflow attempts BTFO
        SafeMath.sub(
          (sqrt
            (
              (_tokenPriceInitial**2)
              +
              (2*(tokenPriceIncremental_ * 1e18)*(_ethereum * 1e18))
              +
              (((tokenPriceIncremental_)**2)*(tokenSupply**2))
              +
              (2*(tokenPriceIncremental_)*_tokenPriceInitial*tokenSupply)
            )
          ), _tokenPriceInitial
        )
      )/(tokenPriceIncremental_)
    )-(tokenSupply);
    return _tokensReceived;
  }
    
  /**
    * Calculate token sell value.
    * It's an algorithm, hopefully we gave you the whitepaper with it in scientific notation;
    * Some conversions occurred to prevent decimal errors or underflows / overflows in solidity code.
    */
  function tokensToEthereum_(uint256 _tokens)
  internal
  view
  returns(uint256)
  {

    uint256 tokens_ = (_tokens + 1e18);
    uint256 _tokenSupply = (tokenSupply + 1e18);
    uint256 _etherReceived =
    (
      // underflow attempts BTFO
      SafeMath.sub(
        (
          (
            (
              tokenPriceInitial_ +(tokenPriceIncremental_ * (_tokenSupply/1e18))
            )-tokenPriceIncremental_
          )*(tokens_ - 1e18)
        ),(tokenPriceIncremental_*((tokens_**2-tokens_)/1e18))/2
      )
    /1e18);
    return _etherReceived;
  }

  function transferFromInternal(address _from, address _toAddress, uint _amountOfTokens)
  internal
  onlySellingPhase
  {
    require(_toAddress != address(0x0));
    address _customerAddress     = _from;
    uint _amountOfFrontEndTokens = _amountOfTokens;

    // Withdraw all outstanding dividends first (including those generated from referrals).
    if(theDividendsOf(true, _customerAddress) > 0) withdrawFrom(_customerAddress);

    // Calculate how many back-end dividend tokens to transfer.
    // This amount is proportional to the caller's average dividend rate multiplied by the proportion of tokens being transferred.
    uint _amountOfDivTokens = _amountOfFrontEndTokens.mul(getUserAverageDividendRate(_customerAddress)).div(magnitude);

    if (_customerAddress != msg.sender){
      // Update the allowed balance.
      // Don't update this if we are transferring our own tokens (via transfer or buyAndTransfer)
      allowed[_customerAddress][msg.sender] -= _amountOfTokens;
    }

    // Exchange tokens
    frontTokenBalanceLedger_[_customerAddress]    = frontTokenBalanceLedger_[_customerAddress].sub(_amountOfFrontEndTokens);
    frontTokenBalanceLedger_[_toAddress]          = frontTokenBalanceLedger_[_toAddress].add(_amountOfFrontEndTokens);
    dividendTokenBalanceLedger_[_customerAddress] = dividendTokenBalanceLedger_[_customerAddress].sub(_amountOfDivTokens);
    dividendTokenBalanceLedger_[_toAddress]       = dividendTokenBalanceLedger_[_toAddress].add(_amountOfDivTokens);

    // Recipient inherits dividend percentage if they have not already selected one.
    if(!userSelectedRate[_toAddress])
    {
      userSelectedRate[_toAddress] = true;
      userDividendRate[_toAddress] = userDividendRate[_customerAddress];
    }

    // Update dividend trackers
    payoutsTo_[_customerAddress] -= (int256) (profitPerDivToken * _amountOfDivTokens);
    payoutsTo_[_toAddress]       += (int256) (profitPerDivToken * _amountOfDivTokens);

    // Fire logging event.
    emit Transfer(_customerAddress, _toAddress, _amountOfFrontEndTokens);
  }

  // Called from transferFrom. Always checks if _customerAddress has dividends.
  function withdrawFrom(address _customerAddress)
  internal
  {
    // Setup data
    uint _dividends = theDividendsOf(false, _customerAddress);

    // update dividend tracker
    payoutsTo_[_customerAddress] +=  (int256) (_dividends * magnitude);

    // add ref. bonus
    _dividends += referralBalance_[_customerAddress];
    referralBalance_[_customerAddress] = 0;

    _customerAddress.transfer(_dividends);

    // Fire logging event.
    emit onWithdraw(_customerAddress, _dividends);
  }


  /*=======================
   =   MATHS FUNCTIONS    =
   ======================*/

  function toPowerOfThreeHalves(uint x) public pure returns (uint) {
    // m = 3, n = 2
    // sqrt(x^3)
    return sqrt(x**3);
  }

  function toPowerOfTwoThirds(uint x) public pure returns (uint) {
    // m = 2, n = 3
    // cbrt(x^2)
    return cbrt(x**2);
  }

  function sqrt(uint x) public pure returns (uint y) {
    uint z = (x + 1) / 2;
    y = x;
    while (z < y) {
      y = z;
      z = (x / z + z) / 2;
    }
  }

  function cbrt(uint x) public pure returns (uint y) {
    uint z = (x + 1) / 3;
    y = x;
    while (z < y) {
      y = z;
      z = (x / (z*z) + 2 * z) / 3;
    }
  }
}