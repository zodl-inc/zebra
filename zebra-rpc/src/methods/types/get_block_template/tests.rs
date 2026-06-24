//! Tests for types and functions for the `getblocktemplate` RPC.

use anyhow::anyhow;
use std::iter;
use zebra_chain::amount::Amount;

use strum::IntoEnumIterator;
use zcash_keys::address::Address;

use zebra_chain::parameters::testnet::ConfiguredFundingStreamRecipient;

use zebra_chain::{
    block::Height,
    parameters::{
        subsidy::FundingStreamReceiver::{Deferred, Ecc, MajorGrants, ZcashFoundation},
        testnet::{self, ConfiguredActivationHeights, ConfiguredFundingStreams},
        Network, NetworkUpgrade,
    },
    serialization::ZcashDeserializeInto,
    transaction::Transaction,
};

use crate::client::TransactionTemplate;
use crate::config::mining::{default_miner_address, Config, MinerAddressType};

use super::{MinerParams, MinerParamsError};

/// Tests that coinbase transactions can be generated.
///
/// This test needs to be run with the `--release` flag so that it runs for ~ 30 seconds instead of
/// ~ 90.
#[test]
#[ignore]
fn coinbase() -> anyhow::Result<()> {
    let regtest = testnet::Parameters::build()
        .with_slow_start_interval(Height::MIN)
        .with_activation_heights(ConfiguredActivationHeights {
            overwinter: Some(1),
            sapling: Some(2),
            blossom: Some(3),
            heartwood: Some(4),
            canopy: Some(5),
            nu5: Some(6),
            nu6: Some(7),
            nu6_1: Some(8),
            nu7: Some(9),
            ..Default::default()
        })?
        .with_funding_streams(vec![
            ConfiguredFundingStreams {
                height_range: Some(Height(1)..Height(100)),
                recipients: Some(vec![
                    ConfiguredFundingStreamRecipient::new_for(Ecc),
                    ConfiguredFundingStreamRecipient::new_for(ZcashFoundation),
                    ConfiguredFundingStreamRecipient::new_for(MajorGrants),
                ]),
            },
            ConfiguredFundingStreams {
                height_range: Some(Height(1)..Height(100)),
                recipients: Some(vec![
                    ConfiguredFundingStreamRecipient::new_for(MajorGrants),
                    ConfiguredFundingStreamRecipient {
                        receiver: Deferred,
                        numerator: 12,
                        addresses: None,
                    },
                ]),
            },
        ])
        .to_network()?;

    for net in Network::iter().chain(iter::once(regtest)) {
        for nu in NetworkUpgrade::iter().filter(|nu| nu >= &NetworkUpgrade::Sapling) {
            if let Some(height) = nu.activation_height(&net) {
                for addr_type in MinerAddressType::iter() {
                    TransactionTemplate::new_coinbase(
                        &net,
                        height,
                        &MinerParams::from(
                            Address::decode(&net, default_miner_address(net.kind(), &addr_type))
                                .ok_or(anyhow!("hard-coded addr must be valid"))?,
                        ),
                        Amount::zero(),
                        #[cfg(all(zcash_unstable = "nu7", feature = "tx_v6"))]
                        None,
                    )?
                    .data()
                    .as_ref()
                    // Deserialization contains checks for elementary consensus rules, which must
                    // pass.
                    .zcash_deserialize_into::<Transaction>()?;
                }
            }
        }
    }

    Ok(())
}

/// Tests that the configured `mining.extra_coinbase_data` is embedded verbatim in the coinbase
/// input script, and that data exceeding the consensus limit is rejected rather than truncated.
///
/// Like [`coinbase`], this builds real coinbase transactions, so it needs the `--release` flag to
/// run in a reasonable time.
#[test]
#[ignore]
fn extra_coinbase_data() -> anyhow::Result<()> {
    const TAG: &str = "my-test-miner";

    let network = Network::Mainnet;
    // NU5 is activated on Mainnet, so its funding streams resolve to addresses and the coinbase
    // builds successfully.
    let height = NetworkUpgrade::Nu5
        .activation_height(&network)
        .ok_or(anyhow!("NU5 must have a Mainnet activation height"))?;

    let miner_address = || -> anyhow::Result<_> {
        Ok(Some(
            default_miner_address(network.kind(), &MinerAddressType::Transparent)
                .parse()
                .map_err(|_| anyhow!("hard-coded miner address must be valid"))?,
        ))
    };

    // A configured tag is included in the coinbase input.
    let config = Config {
        miner_address: miner_address()?,
        extra_coinbase_data: Some(TAG.to_string()),
        ..Default::default()
    };

    let miner_params = MinerParams::new(&network, config)?;

    let coinbase: Transaction = TransactionTemplate::new_coinbase(
        &network,
        height,
        &miner_params,
        Amount::zero(),
        #[cfg(all(zcash_unstable = "nu7", feature = "tx_v6"))]
        None,
    )?
    .data()
    .as_ref()
    .zcash_deserialize_into()?;

    let miner_data = coinbase
        .inputs()
        .first()
        .and_then(|input| input.miner_data())
        .ok_or(anyhow!(
            "the first input of a coinbase tx must be a coinbase input"
        ))?;

    // `extra_coinbase_data` is pushed onto the script sig after the block height, so the configured
    // bytes appear at the end of the coinbase input data (preceded by a push opcode).
    assert!(
        miner_data.ends_with(TAG.as_bytes()),
        "coinbase input data {miner_data:?} should end with the configured tag {:?}",
        TAG.as_bytes(),
    );

    // Data whose encoded length exceeds `MAX_MINER_DATA_LEN` (94 bytes) is rejected when
    // constructing `MinerParams`, rather than being silently truncated. A 95-byte payload is over
    // the limit regardless of push encoding.
    let oversized_config = Config {
        miner_address: miner_address()?,
        extra_coinbase_data: Some("a".repeat(95)),
        ..Default::default()
    };

    assert!(
        matches!(
            MinerParams::new(&network, oversized_config),
            Err(MinerParamsError::OversizedData)
        ),
        "data over MAX_MINER_DATA_LEN must be rejected with OversizedData",
    );

    Ok(())
}
