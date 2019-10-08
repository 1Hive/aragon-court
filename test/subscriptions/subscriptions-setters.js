const { bn, bigExp } = require('../helpers/numbers')
const { assertRevert } = require('../helpers/assertThrow')
const { decodeEventsOfType } = require('../helpers/decodeEvent')
const { assertEvent, assertAmountOfEvents } = require('../helpers/assertEvent')

const CourtSubscriptions = artifacts.require('CourtSubscriptions')
const SubscriptionsOwner = artifacts.require('SubscriptionsOwnerMock')
const JurorsRegistry = artifacts.require('JurorsRegistry')
const ERC20 = artifacts.require('ERC20Mock')

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

contract('CourtSubscriptions', ([_, something, subscriber]) => {
  let subscriptions, subscriptionsOwner, jurorsRegistry, feeToken

  const FEE_AMOUNT = bigExp(10, 18)
  const PREPAYMENT_PERIODS = 12
  const RESUME_PRE_PAID_PERIODS = 10
  const PERIOD_DURATION = 24 * 30           // 30 days, assuming terms are 1h
  const GOVERNOR_SHARE_PCT = bn(100)        // 100‱ = 1%
  const LATE_PAYMENT_PENALTY_PCT = bn(1000) // 1000‱ = 10%

  beforeEach('create base contracts', async () => {
    subscriptions = await CourtSubscriptions.new()
    subscriptionsOwner = await SubscriptionsOwner.new(subscriptions.address)
    jurorsRegistry = await JurorsRegistry.new()
    feeToken = await ERC20.new('Subscriptions Fee Token', 'SFT', 18)
  })

  describe('setFeeAmount', () => {
    context('when the subscriptions was already initialized', () => {
      beforeEach('initialize subscriptions', async () => {
        await subscriptions.init(subscriptionsOwner.address, jurorsRegistry.address, PERIOD_DURATION, feeToken.address, FEE_AMOUNT, PREPAYMENT_PERIODS, RESUME_PRE_PAID_PERIODS, LATE_PAYMENT_PENALTY_PCT, GOVERNOR_SHARE_PCT)
      })

      context('when the sender is the governor', async () => {
        context('when the given value is greater than zero', async () => {
          const newFeeAmount = bn(500)

          it('updates the subscriptions fee amount', async () => {
            await subscriptionsOwner.setFeeAmount(newFeeAmount)

            assert.equal((await subscriptions.currentFeeAmount()).toString(), newFeeAmount.toString(), 'subscription fee amount does not match')
          })

          it('emits an event', async () => {
            const previousFeeAmount = await subscriptions.currentFeeAmount()

            const receipt = await subscriptionsOwner.setFeeAmount(newFeeAmount)

            const logs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'FeeAmountChanged')
            assertAmountOfEvents({ logs }, 'FeeAmountChanged')
            assertEvent({ logs }, 'FeeAmountChanged', { previousFeeAmount, currentFeeAmount: newFeeAmount })
          })
        })

        context('when the given value is zero', async () => {
          const newFeeAmount = bn(0)

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setFeeAmount(newFeeAmount), 'CS_FEE_AMOUNT_ZERO')
          })
        })
      })

      context('when the sender is not the governor', async () => {
        it('reverts', async () => {
          await assertRevert(subscriptions.setFeeAmount(FEE_AMOUNT), 'CS_SENDER_NOT_GOVERNOR')
        })
      })
    })

    context('when the subscriptions is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(subscriptions.setFeeAmount(FEE_AMOUNT), '')
      })
    })
  })

  describe('setFeeToken', () => {
    context('when the subscriptions was already initialized', () => {
      beforeEach('initialize subscriptions', async () => {
        await subscriptions.init(subscriptionsOwner.address, jurorsRegistry.address, PERIOD_DURATION, feeToken.address, FEE_AMOUNT, PREPAYMENT_PERIODS, RESUME_PRE_PAID_PERIODS, LATE_PAYMENT_PENALTY_PCT, GOVERNOR_SHARE_PCT)
      })

      context('when the sender is the governor', async () => {
        context('when the given token address is a contract', async () => {
          let newFeeToken

          beforeEach('deploy new fee token', async () => {
            newFeeToken = await ERC20.new('New Fee Token', 'NFT', 18)
          })

          context('when the given fee amount is greater than zero', async () => {
            const newFeeAmount = bigExp(99, 18)

            const itUpdatesFeeTokenAndAmount = () => {
              it('updates the current fee token address and amount', async () => {
                await subscriptionsOwner.setFeeToken(newFeeToken.address, newFeeAmount)

                assert.equal(await subscriptions.currentFeeToken(), newFeeToken.address, 'fee token does not match')
                assert.equal((await subscriptions.currentFeeAmount()).toString(), newFeeAmount.toString(), 'fee amount does not match')
              })

              it('emits an event', async () => {
                const previousFeeToken = await subscriptions.currentFeeToken()
                const previousFeeAmount = await subscriptions.currentFeeAmount()

                const receipt = await subscriptionsOwner.setFeeToken(newFeeToken.address, newFeeAmount)

                const tokenLogs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'FeeTokenChanged')
                assertAmountOfEvents({ logs: tokenLogs }, 'FeeTokenChanged')
                assertEvent({ logs: tokenLogs }, 'FeeTokenChanged', { previousFeeToken, currentFeeToken: newFeeToken.address })

                const amountLogs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'FeeAmountChanged')
                assertAmountOfEvents({ logs: amountLogs }, 'FeeAmountChanged')
                assertEvent({ logs: amountLogs }, 'FeeAmountChanged', { previousFeeAmount, currentFeeAmount: newFeeAmount })
              })
            }

            context('when there were none governor fees accumulated', async () => {
              itUpdatesFeeTokenAndAmount()
            })

            context('when there were some governor fees accumulated', async () => {
              const paidPeriods = bn(2)
              const paidAmount = FEE_AMOUNT.mul(paidPeriods)
              const governorFees = GOVERNOR_SHARE_PCT.mul(paidAmount).div(bn(10000))

              beforeEach('pay some subscriptions', async () => {
                await subscriptionsOwner.mockSetTerm(PERIOD_DURATION)
                await feeToken.generateTokens(subscriber, paidAmount)
                await feeToken.approve(subscriptions.address, paidAmount, { from: subscriber })
                await subscriptions.payFees(subscriber, paidPeriods, { from: subscriber })
              })

              itUpdatesFeeTokenAndAmount()

              it('transfers the accumulated fees to the governor', async () => {
                const previousGovernorBalance = await feeToken.balanceOf(subscriptionsOwner.address)

                await subscriptionsOwner.setFeeToken(newFeeToken.address, newFeeAmount)

                const currentGovernorBalance = await feeToken.balanceOf(subscriptionsOwner.address)
                assert.equal(previousGovernorBalance.add(governorFees).toString(), currentGovernorBalance.toString(), 'governor shares do not match')
              })

              it('emits a governor share fees transferred event', async () => {
                const receipt = await subscriptionsOwner.setFeeToken(newFeeToken.address, newFeeAmount)
                const logs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'GovernorFeesTransferred')

                assertAmountOfEvents({ logs }, 'GovernorFeesTransferred')
                assertEvent({ logs }, 'GovernorFeesTransferred', { amount: governorFees })
              })
            })
          })

          context('when the given fee amount is zero', async () => {
            const newFeeAmount = bn(0)

            it('reverts', async () => {
              await assertRevert(subscriptionsOwner.setFeeToken(newFeeToken.address, newFeeAmount), 'CS_FEE_AMOUNT_ZERO')
            })
          })
        })

        context('when the given token address is not a contract', async () => {
          const newFeeTokenAddress = something

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setFeeToken(newFeeTokenAddress, FEE_AMOUNT), 'CS_FEE_TOKEN_NOT_CONTRACT')
          })
        })

        context('when the given token address is the zero address', async () => {
          const newFeeTokenAddress = ZERO_ADDRESS

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setFeeToken(newFeeTokenAddress, FEE_AMOUNT), 'CS_FEE_TOKEN_NOT_CONTRACT')
          })
        })
      })

      context('when the sender is not the governor', async () => {
        it('reverts', async () => {
          await assertRevert(subscriptions.setFeeToken(feeToken.address, FEE_AMOUNT), 'CS_SENDER_NOT_GOVERNOR')
        })
      })
    })

    context('when the subscriptions is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(subscriptions.setFeeToken(feeToken.address, FEE_AMOUNT), '')
      })
    })
  })

  describe('setPrePaymentPeriods', () => {
    context('when the subscriptions was already initialized', () => {
      beforeEach('initialize subscriptions', async () => {
        await subscriptions.init(subscriptionsOwner.address, jurorsRegistry.address, PERIOD_DURATION, feeToken.address, FEE_AMOUNT, PREPAYMENT_PERIODS, RESUME_PRE_PAID_PERIODS, LATE_PAYMENT_PENALTY_PCT, GOVERNOR_SHARE_PCT)
      })

      context('when the sender is the governor', async () => {
        const itUpdatesThePrePaymentPeriods = newPrePaymentPeriods => {
          it('updates the pre payment periods number', async () => {
            await subscriptionsOwner.setPrePaymentPeriods(newPrePaymentPeriods)

            assert.equal((await subscriptions.prePaymentPeriods()).toString(), newPrePaymentPeriods.toString(), 'pre payment periods does not match')
          })

          it('emits an event', async () => {
            const previousPrePaymentPeriods = await subscriptions.prePaymentPeriods()

            const receipt = await subscriptionsOwner.setPrePaymentPeriods(newPrePaymentPeriods)
            const logs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'PrePaymentPeriodsChanged')

            assertAmountOfEvents({ logs }, 'PrePaymentPeriodsChanged')
            assertEvent({ logs }, 'PrePaymentPeriodsChanged', { previousPrePaymentPeriods, currentPrePaymentPeriods: newPrePaymentPeriods })
          })
        }

        context('when the given value is greater than zero', async () => {
          const newPrePaymentPeriods = bn(10)

          itUpdatesThePrePaymentPeriods(newPrePaymentPeriods)
        })

        context('when the given value is equal to the resume pre-paid periods', async () => {
          const newPrePaymentPeriods = RESUME_PRE_PAID_PERIODS

          itUpdatesThePrePaymentPeriods(newPrePaymentPeriods)
        })

        context('when the given value is above the resume pre-paid periods', async () => {
          const newPrePaymentPeriods = RESUME_PRE_PAID_PERIODS + 1

          itUpdatesThePrePaymentPeriods(newPrePaymentPeriods)
        })

        context('when the given value is zero', async () => {
          const newPrePaymentPeriods = bn(0)

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setPrePaymentPeriods(newPrePaymentPeriods), 'CS_PREPAYMENT_PERIODS_ZERO')
          })
        })

        context('when the given value is above the resume pre-paid periods', async () => {
          const newPrePaymentPeriods = RESUME_PRE_PAID_PERIODS - 1

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setPrePaymentPeriods(newPrePaymentPeriods), 'CS_RESUME_PRE_PAID_PERIODS_BIG')
          })
        })
      })

      context('when the sender is not the governor', async () => {
        it('reverts', async () => {
          await assertRevert(subscriptions.setPrePaymentPeriods(PREPAYMENT_PERIODS), 'CS_SENDER_NOT_GOVERNOR')
        })
      })
    })

    context('when the subscriptions is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(subscriptions.setPrePaymentPeriods(PREPAYMENT_PERIODS), '')
      })
    })
  })

  describe('setLatePaymentPenaltyPct', () => {
    context('when the subscriptions was already initialized', () => {
      beforeEach('initialize subscriptions', async () => {
        await subscriptions.init(subscriptionsOwner.address, jurorsRegistry.address, PERIOD_DURATION, feeToken.address, FEE_AMOUNT, PREPAYMENT_PERIODS, RESUME_PRE_PAID_PERIODS, LATE_PAYMENT_PENALTY_PCT, GOVERNOR_SHARE_PCT)
      })

      context('when the sender is the governor', async () => {
        const itUpdatesTheLatePaymentsPenalty = newLatePaymentPenaltyPct => {
          it('updates the late payments penalty pct', async () => {
            await subscriptionsOwner.setLatePaymentPenaltyPct(newLatePaymentPenaltyPct)

            assert.equal((await subscriptions.latePaymentPenaltyPct()).toString(), newLatePaymentPenaltyPct.toString(), 'late payments penalty does not match')
          })

          it('emits an event', async () => {
            const previousLatePaymentPenaltyPct = await subscriptions.latePaymentPenaltyPct()

            const receipt = await subscriptionsOwner.setLatePaymentPenaltyPct(newLatePaymentPenaltyPct)
            const logs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'LatePaymentPenaltyPctChanged')

            assertAmountOfEvents({ logs }, 'LatePaymentPenaltyPctChanged')
            assertEvent({ logs }, 'LatePaymentPenaltyPctChanged', { previousLatePaymentPenaltyPct, currentLatePaymentPenaltyPct: newLatePaymentPenaltyPct })
          })
        }

        context('when the given value is zero', async () => {
          const newLatePaymentPenaltyPct = bn(0)

          itUpdatesTheLatePaymentsPenalty(newLatePaymentPenaltyPct)
        })

        context('when the given value is not greater than 10,000', async () => {
          const newLatePaymentPenaltyPct = bn(500)

          itUpdatesTheLatePaymentsPenalty(newLatePaymentPenaltyPct)
        })

        context('when the given value is greater than 10,000', async () => {
          const newLatePaymentPenaltyPct = bn(10001)

          itUpdatesTheLatePaymentsPenalty(newLatePaymentPenaltyPct)
        })
      })

      context('when the sender is not the governor', async () => {
        it('reverts', async () => {
          await assertRevert(subscriptions.setLatePaymentPenaltyPct(LATE_PAYMENT_PENALTY_PCT), 'CS_SENDER_NOT_GOVERNOR')
        })
      })
    })

    context('when the subscriptions is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(subscriptions.setLatePaymentPenaltyPct(LATE_PAYMENT_PENALTY_PCT), '')
      })
    })
  })

  describe('setGovernorSharePct', () => {
    context('when the subscriptions was already initialized', () => {
      beforeEach('initialize subscriptions', async () => {
        await subscriptions.init(subscriptionsOwner.address, jurorsRegistry.address, PERIOD_DURATION, feeToken.address, FEE_AMOUNT, PREPAYMENT_PERIODS, RESUME_PRE_PAID_PERIODS, LATE_PAYMENT_PENALTY_PCT, GOVERNOR_SHARE_PCT)
      })

      context('when the sender is the governor', async () => {
        const itUpdatesTheGovernorSharePct = newGovernorSharePct => {
          it('updates the governor share pct', async () => {
            await subscriptionsOwner.setGovernorSharePct(newGovernorSharePct)

            assert.equal((await subscriptions.governorSharePct()).toString(), newGovernorSharePct.toString(), 'governor share pct does not match')
          })

          it('emits an event', async () => {
            const previousGovernorSharePct = await subscriptions.governorSharePct()

            const receipt = await subscriptionsOwner.setGovernorSharePct(newGovernorSharePct)
            const logs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'GovernorSharePctChanged')

            assertAmountOfEvents({ logs }, 'GovernorSharePctChanged')
            assertEvent({ logs }, 'GovernorSharePctChanged', { previousGovernorSharePct, currentGovernorSharePct: newGovernorSharePct })
          })
        }

        context('when the given value is zero', async () => {
          const newGovernorSharePct = bn(0)

          itUpdatesTheGovernorSharePct(newGovernorSharePct)
        })

        context('when the given value is not greater than 10,000', async () => {
          const newGovernorSharePct = bn(500)

          itUpdatesTheGovernorSharePct(newGovernorSharePct)
        })

        context('when the given value is greater than 10,000', async () => {
          const newGovernorSharePct = bn(10001)

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setGovernorSharePct(newGovernorSharePct), 'CS_OVERRATED_GOVERNOR_SHARE_PCT')
          })
        })
      })

      context('when the sender is not the governor', async () => {
        it('reverts', async () => {
          await assertRevert(subscriptions.setGovernorSharePct(GOVERNOR_SHARE_PCT), 'CS_SENDER_NOT_GOVERNOR')
        })
      })
    })

    context('when the subscriptions is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(subscriptions.setGovernorSharePct(GOVERNOR_SHARE_PCT), '')
      })
    })
  })

  describe('setResumePrePaidPeriods', () => {
    context('when the subscriptions was already initialized', () => {
      beforeEach('initialize subscriptions', async () => {
        await subscriptions.init(subscriptionsOwner.address, jurorsRegistry.address, PERIOD_DURATION, feeToken.address, FEE_AMOUNT, PREPAYMENT_PERIODS, RESUME_PRE_PAID_PERIODS, LATE_PAYMENT_PENALTY_PCT, GOVERNOR_SHARE_PCT)
      })

      context('when the sender is the governor', async () => {
        const itUpdatesTheResumePenalties = (newResumePrePaidPeriods) => {
          it('updates the resume penalties', async () => {
            await subscriptionsOwner.setResumePrePaidPeriods(newResumePrePaidPeriods)

            assert.equal((await subscriptions.resumePrePaidPeriods()).toString(), newResumePrePaidPeriods.toString(), 'resume pre-paid periods does not match')
          })

          it('emits an event', async () => {
            const previousResumePrePaidPeriods = await subscriptions.resumePrePaidPeriods()

            const receipt = await subscriptionsOwner.setResumePrePaidPeriods(newResumePrePaidPeriods)
            const logs = decodeEventsOfType(receipt, CourtSubscriptions.abi, 'ResumePenaltiesChanged')

            assertAmountOfEvents({ logs }, 'ResumePenaltiesChanged')
            assertEvent({ logs }, 'ResumePenaltiesChanged', { previousResumePrePaidPeriods, currentResumePrePaidPeriods: newResumePrePaidPeriods })
          })
        }

        context('when the given values is zero', async () => {
          const newResumePrePaidPeriods = bn(0)

          itUpdatesTheResumePenalties(newResumePrePaidPeriods)
        })

        context('when the given resume pre-paid periods is below the pre-payment periods', async () => {
          const newResumePrePaidPeriods = PREPAYMENT_PERIODS - 1

          itUpdatesTheResumePenalties(newResumePrePaidPeriods)
        })

        context('when the given resume pre-paid periods is equal to the pre-payment periods', async () => {
          const newResumePrePaidPeriods = PREPAYMENT_PERIODS

          itUpdatesTheResumePenalties(newResumePrePaidPeriods)
        })

        context('when the given pre-paid periods is greater than the pre-payment periods', async () => {
          const newResumePrePaidPeriods = PREPAYMENT_PERIODS + 1

          it('reverts', async () => {
            await assertRevert(subscriptionsOwner.setResumePrePaidPeriods(newResumePrePaidPeriods), 'CS_RESUME_PRE_PAID_PERIODS_BIG')
          })
        })
      })

      context('when the sender is not the governor', async () => {
        it('reverts', async () => {
          await assertRevert(subscriptions.setResumePrePaidPeriods(RESUME_PRE_PAID_PERIODS), 'CS_SENDER_NOT_GOVERNOR')
        })
      })
    })

    context('when the subscriptions is not initialized', () => {
      it('reverts', async () => {
        await assertRevert(subscriptions.setResumePrePaidPeriods(RESUME_PRE_PAID_PERIODS), '')
      })
    })
  })
})