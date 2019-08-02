pragma solidity >=0.4.21 <0.6.0;

//  Imports:
import '@gnosis.pm/dx-contracts/contracts/DutchExchange.sol';
import '../../GelatoCore.sol';
import '../../base/Counters.sol';
import '../../base/ERC20.sol';
import '../../base/IcedOut.sol';
import '../../base/Ownable.sol';
import '../../base/SafeMath.sol';


// Gelato IcedOut-compliant DutchX Interface for splitting sell orders and for automated withdrawals
contract GelatoDutchX is IcedOut, Ownable, SafeTransfer {
    // Libraries
    using SafeMath for uint256;
    using Counters for Counters.Counter;

    Counters.Counter private _OrderIds;

    struct OrderState {
        address sellToken;
        address buyToken;
        bool lastAuctionWasWaiting;  // default: false
        uint256 lastAuctionIndex;  // default: 0
        uint256 prePaymentPerSellOrder;
    }

    struct SellOrder {
        uint256 orderStateId;
        uint256 executionTime;
        uint256 amount;
        bool sold;
    }

    // Legacy Core Struct
    /*
    struct ExecutionClaim {
        address dappInterface;
        uint256 interfaceOrderId;
        address sellToken;
        address buyToken;
        uint256 sellAmount;  // you always sell something, in order to buy something
        uint256 executionTime;
        uint256 prepaidExecutionFee;
    }
    */

    // **************************** Events ******************************
    event LogNewOrderCreated(uint256 indexed orderId, address indexed seller);
    event LogFeeNumDen(uint256 num, uint256 den);
    event LogActualSellAmount(uint256 indexed executionClaimId,
                              uint256 indexed orderId,
                              uint256 subOrderAmount,
                              uint256 actualSellAmount,
                              uint256 dutchXFee
    );
    event LogOrderCancelled(uint256 indexed executionClaimId,
                            uint256 indexed orderID,
                            address indexed seller
    );
    event LogWithdrawComplete(uint256 indexed executionClaimId,
                              uint256 indexed orderId,
                              address indexed seller,
                              address buyToken,
                              uint256 withdrawAmount
    );
    event LogOrderCompletedAndDeleted(uint256 indexed orderId);
    event LogWithdrawAmount(uint256 num, uint256 den, uint256 withdrawAmount);
    // **************************** Events END ******************************


    // **************************** State Variables ******************************

    // Interfaces to other contracts that are set during construction.
    GelatoCore public gelatoCore;
    DutchExchange public dutchExchange;

    // One orderState struct can have many sellOrder structs as children

    // OrderId => parent orderState struct
    mapping(uint256 => OrderState) public orderStates;

    // gelatoCore executionId => individual sellOrder struct
    mapping(uint256 => SellOrder) public sellOrders;

    // Constants that are set during contract construction and updateable via setters
    uint256 public auctionStartWaitingForFunding;

    // Max Gas for one execute + withdraw pair
    uint256 public maxGas;

    // Capping the number of sub Order that can be created in one tx
    uint256 public maxSellOrders;

    // **************************** State Variables END ******************************

    /* constructor():
        * constructs Ownable base and sets msg.sender as owner.
        * connects the contract interfaces to deployed instances thereof.
        * sets the state variable constants
    */
    constructor(address payable _GelatoCore, address _DutchExchange)
        public
    {
        gelatoCore = GelatoCore(_GelatoCore);
        dutchExchange = DutchExchange(_DutchExchange);
        auctionStartWaitingForFunding = 1;
        maxGas = 100000;
        maxSellOrders = 6;
    }


    // **************************** State Variable Setters ******************************
    function setAuctionStartWaitingForFunding(uint256 _auctionStartWaitingForFunding)
        onlyOwner
        external
    {
        auctionStartWaitingForFunding = _auctionStartWaitingForFunding;
    }
    // **************************** State Variable Setters END ******************************

    // Function to calculate the prepayment an interface needs to transfer to Gelato Core
    //  for minting a new execution executionClaim
    function calcPrepaidExecutionFee()
        public
        view
        returns(uint256 prepayment)
    {
        // msg.sender == dappInterface
        prepayment = maxGas.mul(gelatoCore.getGelatoGasPrice());
    }

    // **************************** splitSellOrder() ******************************
    function splitSellOrder(address _sellToken,
                            address _buyToken,
                            uint256 _totalSellVolume,
                            uint256 _numSellOrders,
                            uint256 _sellOrderAmount,
                            uint256 _executionTime,
                            uint256 _intervalSpan
    )
        public
        payable
        returns (bool)

    {
        // LEGACY CORE REQUIRES
        // Step1.1: Zero value preventions
        require(_sellToken != address(0), "GelatoCore.mintExecutionClaim: _sellToken: No zero addresses allowed");
        require(_buyToken != address(0), "GelatoCore.mintExecutionClaim: _buyToken: No zero addresses allowed");
        require(_sellOrderAmount != 0, "GelatoCore.mintExecutionClaim: _sellOrderAmount cannot be 0");
        // Further prevention of zero values is done in Gelato gelatoCore protocol
        require(_totalSellVolume != 0, "splitSellOrder: totalSellVolume cannot be 0");
        require(_numSellOrders != 0, "splitSellOrder: numSubOrders cannot be 0");
        require(_intervalSpan >= 6 hours,
            "splitSellOrder: _intervalSpan not at/above minimum of 6 hours"
        );
        // Step1.2: Valid execution Time check
        // @🐮 I dont think the execution time has to be in the future
        // require(_executionTime >= now, "GelatoCore.mintExecutionClaim: Failed test: Execution time must be in the future");

        uint256 prePaymentPerSellOrder = calcPrepaidExecutionFee();

        // Step2: Require that user transfers the correct prepayment amount. Charge 2x execute + Withdraw
        require(msg.value == prePaymentPerSellOrder.mul(_numSellOrders),  // calc for msg.sender==dappInterface
            "User ETH prepayment transfer is incorrect"
        );

        // Require that number of Suborder does not exceed the max
        require(maxSellOrders >= _numSellOrders, "Too many sub orders for one transaction");

        // Only tokens that are tradeable on the Dutch Exchange can be sold
        require(dutchExchange.getAuctionIndex(_sellToken, _buyToken) != 0, "The selected tokens are not traded on the Dutch Exchange");

        /* Step2: Invariant Requirements
        Handled by dappInterface:
            * 1: subOrderSizes from one Sell Order are constant.
                * totalSellVolume == numSubOrders * subOrderSize.
        Set off-chain (web3) and checked on core protocol:
            * 2: The caller transfers the correct amount of ether as gelato fee endowment
                * msg.value == numSubOrders * gelatoFeePerSubOrder
        */
        // Invariant1: Constant childOrderSize
        require(_totalSellVolume == _numSellOrders.mul(_sellOrderAmount),
            "splitSellOrder: _totalSellVolume != _numSellOrders * _sellOrderAmount"
        );

        // Step3: Transfer the totalSellVolume from msg.sender(seller) to this contract
        // this is hardcoded into SafeTransfer.sol
        require(safeTransfer(_sellToken, address(this), _totalSellVolume, true),
            "splitSellOrder: The transfer of sellTokens from msg.sender to Gelato Interface must succeed"
        );

        // Step4: Instantiate new dutchExchange-specific sell order state
        OrderState memory orderState = OrderState(
            _sellToken,
            _buyToken,
            false,  // default: lastAuctionWasWaiting
            0,  // default: lastAuctionIndex
            prePaymentPerSellOrder
        );

        // Step5: give OrderId: yields core protocol's parentOrderId
        // Increment the current OrderId
        Counters.increment(_OrderIds);
        // Get a new, unique OrderId for the newly created Sell Order
        uint256 orderStateId = _OrderIds.current();
        // Step6: Update GelatoDutchX state variables
        orderStates[orderStateId] = orderState;


        // Step7: Create all subOrders and transfer the gelatoFeePerSubOrder
        for (uint256 i = 0; i < _numSellOrders; i++) {
            //  ***** GELATO CORE PROTOCOL INTERACTION *****
            SellOrder memory sellOrder = SellOrder(
                orderStateId,
                _sellOrderAmount,
                _executionTime.add(_intervalSpan.mul(i)),
                false // not withdrawn yet
            );

            uint256 executionClaimId = gelatoCore.getCurrentExecutionClaimId().add(1);
            bytes memory execSignature = abi.encodeWithSignature("execDepositAndSell(uint256)", executionClaimId);
            gelatoCore.mintExecutionClaim(execSignature, msg.sender);

            uint256 executionClaimIdPlusOne = executionClaimId.add(1);
            bytes memory withdrawSignature = abi.encodeWithSignature("execWithdraw(uint256)", executionClaimIdPlusOne);
            gelatoCore.mintExecutionClaim(withdrawSignature, msg.sender);

            // Map both claims to the same Sell Order
            sellOrders[executionClaimId] = sellOrder;
            sellOrders[executionClaimIdPlusOne] = sellOrder;
            //  *** GELATO CORE PROTOCOL INTERACTION END ***
        }


        // Step8: Emit New Sell Order to find its suborder constituent claims on the Core
        emit LogNewOrderCreated(orderStateId, msg.sender);
        return true;
    }
    // **************************** splitSellOrder() END ******************************



    // **************************** IcedOut execute(executionClaimId) *********************************
    /**
     * DEV: For the GelDutchXSplitSellAndWithdraw interface the IcedOut execute fn does this:
     * First: it tries to post the subOrder on the DutchExchange via depositAndSell()
     * Then (depends on orderState): it attempts to claimAndWithdraw() previous subOrders from the DutchExchange
     * Finally (depends on orderState): it deletes the orderState from this Gelato Interface contract.
     */
    function execDepositAndSell(uint256 _executionClaimId)
        external
    {
        // Step1: Checks for execution safety
        // Make sure that gelatoCore is the only allowed caller to this function.
        // Executors will call this execute function via the Core's execute function.
        require(msg.sender == address(gelatoCore),
            "GelatoInterface.execute: msg.sender != gelatoCore instance address"
        );
        // Ensure that the executionClaim on the Core is linked to this Gelato Interface
        require(gelatoCore.getClaimInterface(_executionClaimId) == address(this),
            "GelatoInterface.execute: gelatoCore.getClaimInterface(_executionClaimId) != address(this)"
        );

        // Fetch SellOrder
        SellOrder storage sellOrder = sellOrders[_executionClaimId];

        // Fetch OrderState
        uint256 orderStateId = sellOrder.orderStateId;
        OrderState storage orderState = orderStates[orderStateId];

        /*
        struct OrderState {
            address sellToken;
            address buyToken;
            bool lastAuctionWasWaiting;  // default: false
            uint256 lastAuctionIndex;  // default: 0
            uint256 remainingSubOrders;  // default: == numSubOrders
        }

        struct sellOrder {
            uint256 orderStateid;
            uint256 executionTime;
            uint256 SellAmountAfterFee;
            bool readyToWithdraw;
        }
        */



        // CHECKS: executionTime
        // Anyone is allowed to be an executor and call this function.
        // All ExecutionClaims in existence are always in state pending/executable (else non-existant/deleted)
        require(sellOrder.executionTime <= now,
            "gelatoCore.execute: You called before scheduled execution time"
        );


        // Step2: fetch from gelatoCore and initialise multi-use variables



        // ********************** Step3: Load variables from storage and initialise them **********************
        // the last DutchX auctionIndex at which the orderId participated in
        address sellToken = orderState.sellToken;
        address buyToken = orderState.buyToken;
        uint256 amount = sellOrder.amount;
        uint256 lastAuctionIndex = orderState.lastAuctionIndex;  // default: 0
        // SubOrderAmount - DutchXFee of last executed subOrder
        // ********************** Step3: Load variables from storage and initialise them END **********************

        // ********************** Step4: Fetch data from dutchExchange **********************
        uint256 newAuctionIndex = dutchExchange.getAuctionIndex(sellToken, buyToken);
        uint256 auctionStartTime = dutchExchange.getAuctionStart(sellToken, buyToken);
        // ********************** Step4: Fetch data from dutchExchange END **********************


        // ********************** Step5: Execution Logic **********************
        /* Basic Execution Logic
            * Handled by Gelato Core
                * Require that order is ready to be executed based on time
            * Handled by this Gelato Interface
                * Require that this Gelato Interface has the ERC20 to be sold
                in its ERC20 balance.
        */
        require(
            ERC20(sellToken).balanceOf(address(this)) >= amount,
            "GelatoInterface.execute: ERC20(sellToken).balanceOf(address(this)) !>= subOrderSize"
        );

        // Waiting Period variables needed to prevent double participation in DutchX auctions
        bool lastAuctionWasWaiting = orderState.lastAuctionWasWaiting;  // default: false
        bool newAuctionIsWaiting;
        // Check if we are in a Waiting period or auction running period
        if (auctionStartTime > now || auctionStartTime == auctionStartWaitingForFunding) {
            newAuctionIsWaiting = true;
        } else if (auctionStartTime < now) {
            newAuctionIsWaiting = false;
        }

        /* Assumptions:
            * 1: Don't sell in the same auction twice
            * 2: Don't sell into an auction before the prior auction you sold into
                    has cleared so we can withdraw safely without prematurely overwriting
                    the OrderState values that must be shared between consecutive subOrders.
        */
        // CASE 1:
        // Check case where lastAuctionIndex is greater than newAuctionIndex
        require(newAuctionIndex >= lastAuctionIndex,
            "Case 1: Fatal error, Gelato auction index ahead of dutchExchange auction index"
        );

        // CASE 2:
        // Either we already sold during waitingPeriod OR during the auction that followed
        if (newAuctionIndex == lastAuctionIndex) {
            // Case2a: Last sold during waitingPeriod1, new CANNOT sell during waitingPeriod1.
            if (lastAuctionWasWaiting && newAuctionIsWaiting) {
                revert("Case2a: Last sold during waitingPeriod1, new CANNOT sell during waitingPeriod1");
            }
            /* Case2b: We sold during waitingPeriod1, our funds went into auction1,
            now auction1 is running, now we DO NOT sell again during auction1, even
            though this time our funds would go into auction2. But we wait for
            the auction index to be incremented */
            else if (lastAuctionWasWaiting && !newAuctionIsWaiting) {
                // Given new assumption of not wanting to sell in newAuction before lastAuction sold-into has finished, revert. Otherwise, holds true for not investing in same auction assupmtion
                revert("Case2b: Selling again before the lastAuction participation cleared disallowed");
            }
            /* Case2c Last sold during running auction1, new tries to sell during waiting period
            that preceded auction1 (impossible time-travel) or new tries to sell during waiting
            period succeeding auction1 (impossible due to auction index incrementation ->
            newAuctionIndex == lastAuctionIndex cannot be true - Gelato-dutchExchange indexing
            must be out of sync) */
            else if (!lastAuctionWasWaiting && newAuctionIsWaiting) {
                revert("Case2c: Fatal error: auction index incrementation out of sync");
            }
            // Case2d: Last sold during running auction1, new CANNOT sell during auction1.
            else if (!lastAuctionWasWaiting && !newAuctionIsWaiting) {
                revert("Case2d: Selling twice into the same running auction is disallowed");
            }
        }
        // CASE 3:
        // We participated at previous auction index
        // Either we sold during previous waiting period, or during previous auction.
        else if (newAuctionIndex == lastAuctionIndex.add(1)) {
            /* Case3a: We sold during previous waiting period, our funds went into auction1,
            then auction1 ran, then auction1 cleared and the auctionIndex got incremented,
            we now sell during the next waiting period, our funds will go to auction2 */
            if (lastAuctionWasWaiting && newAuctionIsWaiting) {
                // ### EFFECTS ###
                // Update Order State
                orderState.lastAuctionWasWaiting = newAuctionIsWaiting;
                orderState.lastAuctionIndex = newAuctionIndex;
                uint256 dutchXFee;
                (sellOrder.amount, dutchXFee) = _calcActualSellAmount(amount);

                emit LogActualSellAmount(_executionClaimId,
                                            orderStateId,
                                            amount,
                                            sellOrder.amount,
                                            dutchXFee
                );
                // Mark sellOrder as sold
                sellOrder.sold = true;

                // ### EFFECTS END ###

                // INTERACTION: sell on dutchExchange
                _depositAndSell(sellToken, buyToken, amount);
            }
            /* Case3b: We sold during previous waiting period, our funds went into auction1, then
            auction1 ran, then auction1 cleared and the auction index was incremented,
            , then a waiting period passed, now we are selling during auction2, our funds
            will go into auction3 */
            else if (lastAuctionWasWaiting && !newAuctionIsWaiting) {
                // ### EFFECTS ###
                // Update Order State
                orderState.lastAuctionWasWaiting = newAuctionIsWaiting;
                orderState.lastAuctionIndex = newAuctionIndex;
                uint256 dutchXFee;
                (sellOrder.amount, dutchXFee) = _calcActualSellAmount(amount);

                emit LogActualSellAmount(_executionClaimId,
                                            orderStateId,
                                            amount,
                                            sellOrder.amount,
                                            dutchXFee
                );

                // Mark sellOrder as sold
                sellOrder.sold = true;

                // ### EFFECTS END ###

                // INTERACTION: sell on dutchExchange
                _depositAndSell(sellToken, buyToken, amount);
            }
            /* Case3c: We sold during auction1, our funds went into auction2, then auction1 cleared
            and the auction index was incremented, now we are NOT selling during the ensuing
            waiting period because our funds would also go into auction2 */
            else if (!lastAuctionWasWaiting && newAuctionIsWaiting) {
                revert("Case3c: Failed: Selling twice during auction and ensuing waiting period disallowed");
            }
            /* Case3d: We sold during auction1, our funds went into auction2, then auction1
            cleared and the auctionIndex got incremented, then a waiting period passed, now
            we DO NOT sell during the running auction2, even though our funds will go to
            auction3 because we only sell after the last auction that we contributed to
            , in this case auction2, has been cleared and its index incremented */
            else if (!lastAuctionWasWaiting && !newAuctionIsWaiting) {
                // Given new assumption of not wanting to sell in newAuction before lastAuction sold-into has finished, revert. Otherwise, holds true for not investing in same auction assupmtion
                revert("Case 3d: Don't sell before last auction seller participated in has cleared");
            }
        }
        // CASE 4:
        // If we skipped at least one auction before trying to sell again: ALWAYS SELL
        else if (newAuctionIndex >= lastAuctionIndex.add(2)) {
            // ### EFFECTS ###
            // Update Order State
            orderState.lastAuctionWasWaiting = newAuctionIsWaiting;
            orderState.lastAuctionIndex = newAuctionIndex;
            uint256 dutchXFee;
            (sellOrder.amount, dutchXFee) = _calcActualSellAmount(amount);

            emit LogActualSellAmount(_executionClaimId,
                                        orderStateId,
                                        amount,
                                        sellOrder.amount,
                                        dutchXFee
            );

            // Mark sellOrder as sold
            sellOrder.sold = true;

            // ### EFFECTS END ###


            // INTERACTION: sell on dutchExchange
            _depositAndSell(sellToken, buyToken, amount);
        }
        // Case 5: Unforeseen stuff
        else {
            revert("Case5: Fatal Error: Case5 unforeseen");
        }
        // ********************** Step5: Execution Logic END **********************

    }
    // **************************** IcedOut execute(executionClaimId) END *********************************

    // Withdraw function executor will call
    function execWithdraw(uint256 _executionClaimId)
        public
    {
        // Fetch SellOrder
        SellOrder storage sellOrder = sellOrders[_executionClaimId];
        address seller = gelatoCore.ownerOf(_executionClaimId);

        // Fetch OrderState
        uint256 orderStateId = sellOrder.orderStateId;
        OrderState memory orderState = orderStates[orderStateId];

        // CHECKS
        require(sellOrder.sold, "Sell Order must have been sold in order to withdraw");

        // DEV use memory value lastAuctionIndex & sellAmountAfterFee as we already updated storage values
        uint amount = sellOrder.amount;

        // delete sellOrder
        delete sellOrders[_executionClaimId];

        // Calculate withdraw amount
        uint256 withdrawAmount = _withdraw(seller,
                                           orderState.sellToken,
                                           orderState.buyToken,
                                           orderState.lastAuctionIndex,
                                           amount //Actual amount sold
        );

        // Event emission
        emit LogWithdrawComplete(_executionClaimId,
                                 orderStateId,
                                 seller,
                                 orderState.buyToken,
                                 withdrawAmount
        );

        // Delete OrderState struct when last withdrawal completed
        // if (orderState.remainingWithdrawals == 0) {
        //     delete orderStates[orderId];
        //     emit LogOrderCompletedAndDeleted(orderId);
        // }
    }

    // **************************** Helper functions *********************************
    // Calculate sub order size accounting for current dutchExchange liquidity contribution fee.
    function _calcActualSellAmount(uint256 _subOrderSize)
        public
        returns(uint256 actualSellAmount, uint256 dutchXFee)
    {
        // Get current fee ratio of Gelato contract
        uint256 num;
        uint256 den;
        // Returns e.g. num = 1, den = 500 for 0.2% fee
        (num, den) = dutchExchange.getFeeRatio(address(this));

        emit LogFeeNumDen(num, den);

        // Calc fee amount
        dutchXFee = _subOrderSize.mul(num).div(den);

        // Calc actual Sell Amount
        actualSellAmount = _subOrderSize.sub(dutchXFee);
    }

    // Deposit and sell on the dutchExchange
    function _depositAndSell(address _sellToken,
                             address _buyToken,
                             uint256 _sellAmount
    )
        private
    {
        // Approve DutchX to transfer the funds from gelatoInterface
        ERC20(_sellToken).approve(address(dutchExchange), _sellAmount);

        // DEV deposit and sell on the dutchExchange
        dutchExchange.depositAndSell(_sellToken, _buyToken, _sellAmount);
    }

    // Internal fn that withdraws funds from dutchExchange to the sellers account
    function _withdraw(address _seller,
                       address _sellToken,
                       address _buyToken,
                       uint256 _lastAuctionIndex,
                       uint256 _sellAmountAfterFee
    )
        public
        returns(uint256 withdrawAmount)
    {
        // Calc how much the amount of buy_tokens received in the previously participated auction
        withdrawAmount = _calcWithdrawAmount(_sellToken,
                                             _buyToken,
                                             _lastAuctionIndex,
                                             _sellAmountAfterFee
        );

        // Withdraw funds from dutchExchange to Gelato
        // DEV uses memory value lastAuctionIndex in case execute func calls it as we already incremented storage value
        dutchExchange.claimAndWithdraw(_sellToken,
                                       _buyToken,
                                       address(this),
                                       _lastAuctionIndex,
                                       withdrawAmount
        );

        // Transfer Tokens from Gelato to Seller
        safeTransfer(_buyToken, _seller, withdrawAmount, false);
    }

    // DEV Calculates amount withdrawable from past, cleared auction
    function _calcWithdrawAmount(address _sellToken,
                                 address _buyToken,
                                 uint256 _lastAuctionIndex,
                                 uint256 _sellAmountAfterFee
    )
        public
        returns(uint256 withdrawAmount)
    {
        // Fetch numerator and denominator from dutchExchange
        uint256 num;
        uint256 den;

        // FETCH PRICE OF CLEARED ORDER WITH INDEX lastAuctionIndex
        // num: buyVolumeOpp || den: sellVolumeOpp
        // Ex: num = 1000, den = 10 => 1WETH === 100RDN
        (num, den) = dutchExchange.closingPrices(_sellToken,
                                                 _buyToken,
                                                 _lastAuctionIndex
        );

        // Check if the last auction the seller participated in has cleared
        // DEV Check line 442 in dutchExchange contract
        // DEV Test: Are there any other possibilities for den being 0 other than when the auction has not yet cleared?
        require(den != 0,
            "withdrawManually: den != 0, Last auction did not clear thus far, you have to wait"
        );

        emit LogWithdrawAmount(num, den, _sellAmountAfterFee.mul(num).div(den));

        withdrawAmount = _sellAmountAfterFee.mul(num).div(den);

    }
    // **************************** Helper functions END *********************************



    // **************************** Extra functions *********************************
    // Allows sellers to cancel their deployed orders
    function cancelOrder(uint256 _executionClaimId)
        public
        returns(bool)
    {
        // MAKE THAT MANUAL WITHDRAW CANCELS THE WITHDRAW CLAIM
        // Fetch SellOrder
        SellOrder memory sellOrder = sellOrders[_executionClaimId];

        // Require that sold == False, as users can only cancel sell orders that havent been sold yet
        require(sellOrder.sold == false, "User can only cancel sell orders that were not sold yet");

        // Fetch OrderState
        uint256 orderStateId = sellOrder.orderStateId;
        OrderState memory orderState = orderStates[orderStateId];

        // CHECKS: msg.sender == executionClaimOwner is checked by Core

        // ****** EFFECTS ******
        // Emit event before deletion/burning of relevant variables
        emit LogOrderCancelled(_executionClaimId, orderStateId, gelatoCore.ownerOf(_executionClaimId));
        /**
         *DEV: cancel the ExecutionClaim via gelatoCore.cancelExecutionClaim(executionClaimId)
         * This has the following effects on the Core:
         * 1) It burns the ExecutionClaim
         * 2) It deletes the ExecutionClaim from the executionClaims mapping
         * 3) It transfers ether as a refund to the executionClaimOwner
         */

        // ** Gelato Core interactions **
        gelatoCore.cancelExecutionClaim(_executionClaimId);
        // ** Gelato Core interactions END **

        SellOrder memory sellOrderWithdraw = sellOrders[_executionClaimId.add(1)];

        // If the next executionClaimId maps to the same sellOrder, also cancel it.
        if (keccak256(abi.encode(sellOrder.executionTime, sellOrder.amount)) == keccak256(abi.encode(sellOrderWithdraw.executionTime, sellOrderWithdraw.amount)))
        {
            gelatoCore.cancelExecutionClaim(_executionClaimId.add(1));
        }

        // Fetch variables needed before deletion
        address sellToken = orderState.sellToken;
        uint256 sellAmount = sellOrder.amount;

        // ****** EFFECTS END ******
        // This deletes the withdraw struct as well as they both map to the same struct
        sellOrders[_executionClaimId];

        // REFUND USER!!!
        // IN order to refund the exact amount the user prepaid, we need to store that information on-chain
        msg.sender.transfer(orderState.prePaymentPerSellOrder);

        // INTERACTIONS: transfer sellAmount back from this contracts ERC20 balance to seller
        safeTransfer(sellToken, msg.sender, sellAmount, false);

        // Success
        return true;
    }

    // Allows manual withdrawals on behalf of a seller from any calling address
    // This is allowed also on the GelatoDutchX Automated Withdrawal Interface
    //  because all remaining claims are still executable (do not throw revert as a result)
    //  since they still do postSellOrder. Actually they could now even be a bit cheaper
    //   to execute for the executor, as no withdrawal control flow is entered any more.
    // withdrawManually only works up until the last withdrawal because the last withdrawal is its
    //  own ExecutionClaim on the Core, and a manual withdrawal thereof would result in unwanted complexity.
    function withdrawManually(uint256 _executionClaimId)
        external
        returns(bool)
    {
        // MAKE THAT MANUAL WITHDRAW CANCELS THE WITHDRAW CLAIm
        // Fetch SellOrder
        SellOrder memory sellOrder = sellOrders[_executionClaimId];

        // Fetch OrderState
        uint256 orderStateId = sellOrder.orderStateId;
        OrderState memory orderState = orderStates[orderStateId];

        // CHECKS
        // Check whether sold == true
        require(sellOrder.sold, "Sell Order must have been sold in order to withdraw");

        // DEV use memory value lastAuctionIndex & sellAmountAfterFee as we already updated storage values
        uint amount = sellOrder.amount;
        require(amount != 0, "Amount for manual withdraw cannot be zero");

        // **** CHECKS ****
        // Do not allow if last withdrawal as corresponding ExecutionClaim
        //  would need its own executionClaim to be passed in parameters, in order to be
        //  cancelled, as uncancelled it will throw revert upon execution attempt by executor.
        // Require that tx executor hasnt already withdrawn the funds

        // Fetch price of last participated in and cleared auction using lastAuctionIndex
        uint256 num;
        uint256 den;
        (num, den) = dutchExchange.closingPrices(orderState.sellToken, orderState.buyToken, orderState.lastAuctionIndex);

        // Require that the last auction the seller participated in has cleared
        // DEV Check line 442 in dutchExchange contract
        require(den != 0,
            "withdrawManually: den != 0, Last auction did not clear thus far, you have to wait"
        );
        // **** CHECKS END ***

        // **** EFFECTS ****
        // Delete sellOrder Struct
        delete sellOrders[_executionClaimId];
        // **** EFFECTS END****

        // INTERACTIONS: Initiate withdraw
        _withdraw(gelatoCore.ownerOf(_executionClaimId),  // seller
                  orderState.sellToken,
                  orderState.buyToken,
                  orderState.lastAuctionIndex,
                  amount
        );

        // Success
        return true;
    }

    // Set the global max gas price an executor can receive in the gelato system
    function setMaxGas(uint256 _maxGas)
        public
        onlyOwner
    {
        maxGas = _maxGas;
    }

    // Set the global fee an executor can receive in the gelato system
    function setMaxExecutions(uint256 _maxSellOrders)
        public
        onlyOwner
    {
        maxSellOrders = _maxSellOrders;
    }

    // Fallback function: reverts incoming ether payments not addressed to a payable function
    function() external payable {
        revert("Should not send ether to GelatoDutchXSplitSellAndWithdraw without specifying a payable function selector");
    }
    // **************************** Extra functions END *********************************
}


