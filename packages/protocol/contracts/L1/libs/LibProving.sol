// SPDX-License-Identifier: MIT
//  _____     _ _         _         _
// |_   _|_ _(_) |_____  | |   __ _| |__ ___
//   | |/ _` | | / / _ \ | |__/ _` | '_ (_-<
//   |_|\__,_|_|_\_\___/ |____\__,_|_.__/__/

pragma solidity ^0.8.9;

import {IProofVerifier} from "../ProofVerifier.sol";
import "../../common/AddressResolver.sol";
import "../../libs/LibAnchorSignature.sol";
import "../../libs/LibBlockHeader.sol";
import "../../libs/LibReceiptDecoder.sol";
import "../../libs/LibTxDecoder.sol";
import "../../libs/LibTxUtils.sol";
import "../../thirdparty/LibBytesUtils.sol";
import "../../thirdparty/LibRLPWriter.sol";
import "./LibUtils.sol";

/// @author dantaik <dan@taiko.xyz>
/// @author david <david@taiko.xyz>
library LibProving {
    using LibBlockHeader for BlockHeader;
    using LibUtils for TaikoData.BlockMetadata;
    using LibUtils for TaikoData.State;

    struct Evidence {
        TaikoData.BlockMetadata meta;
        BlockHeader header;
        address prover;
        bytes[] proofs; // The first zkProofsPerBlock are ZKPs,
        // followed by MKPs.
        uint16[] circuits; // The circuits IDs (size === zkProofsPerBlock)
    }

    bytes32 public constant INVALIDATE_BLOCK_LOG_TOPIC =
        keccak256("BlockInvalidated(bytes32)");

    bytes4 public constant ANCHOR_TX_SELECTOR =
        bytes4(keccak256("anchor(uint256,bytes32)"));

    event BlockProven(
        uint256 indexed id,
        bytes32 parentHash,
        bytes32 blockHash,
        uint64 timestamp,
        uint64 provenAt,
        address prover
    );

    error ErrProvingInvalidInputsLength(uint expectedLength);
    error ErrProvingBlockIdOutOfRange();
    error ErrProvingBlockIdMismatch();
    error ErrProvingBlockMetahashMismatch();
    error ErrProvingInvalidProofsLength();
    error ErrProvingInvalidCircitsLength();
    error ErrProposingZeroProverAddress();
    error ErrProvingOracleProverMustBeTheFistProver();
    error ErrProvingCanontProveBeforeOracleProver();
    error ErrProvingInvalidZKProof();
    error ErrProvingConflictingProofs();
    error ErrProvingDuplicateProofs();
    error ErrProvingTooLateToProveBlock();
    error ErrProvingBlockHasTooManyProofs();
    error ErrProvingAnchorTxType();
    error ErrProvingAnchorTxDestinationNotTaikoL1();
    error ErrProvingAnchorTxInvalidGasLimit();
    error ErrProvingAnchorTxInvalidCalldata();
    error ErrProvingAnchorTxInvalidTransactionMerkleProof();
    error ErrProvingAnchorTxInvalidReceiptMerkleProof();
    error ErrProvingAnchorTxInvalidReceiptStatus();
    error ErrProvingAnchorTxInvalidReceiptLogSize();
    error ErrProvingAnchorTxInvalidReceiptDestination();
    error ErrProvingAnchorTxInvalidReceiptLogData();
    error ErrProvingAnchorTxInvalidReceiptLogTopics();
    error ErrProvingAnchorTxSignatureInvalidR();
    error ErrProvingAnchorTxSignatureInvalidS();

    function proveBlock(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        AddressResolver resolver,
        uint256 blockId,
        bytes[] calldata inputs
    ) public {
        LibUtils.assertNotHalted(state);

        // Check and decode inputs
        if (inputs.length != 3) {
            revert ErrProvingInvalidInputsLength(3);
        }
        Evidence memory evidence = abi.decode(inputs[0], (Evidence));

        bytes calldata anchorTx = inputs[1];
        bytes calldata anchorReceipt = inputs[2];

        // Check evidence
        if (evidence.meta.id != blockId) {
            revert ErrProvingBlockIdMismatch();
        }

        uint256 zkProofsPerBlock = config.zkProofsPerBlock;
        if (evidence.proofs.length != 2 + zkProofsPerBlock) {
            revert ErrProvingInvalidProofsLength();
        }
        if (evidence.circuits.length != zkProofsPerBlock) {
            revert ErrProvingInvalidCircitsLength();
        }

        IProofVerifier proofVerifier = IProofVerifier(
            resolver.resolve("proof_verifier", false)
        );

        if (config.enableProofValidation) {
            // Check anchor tx is valid
            LibTxDecoder.Tx memory _tx = LibTxDecoder.decodeTx(
                config.chainId,
                anchorTx
            );
            if (_tx.txType != 0) revert ErrProvingAnchorTxType();
            if (
                _tx.destination !=
                resolver.resolve(config.chainId, "taiko", false)
            ) {
                revert ErrProvingAnchorTxDestinationNotTaikoL1();
            }
            if (_tx.gasLimit != config.anchorTxGasLimit) {
                revert ErrProvingAnchorTxInvalidGasLimit();
            }

            // Check anchor tx's signature is valid and deterministic
            _validateAnchorTxSignature(config.chainId, _tx);

            // Check anchor tx's calldata is valid
            if (
                !LibBytesUtils.equal(
                    _tx.data,
                    bytes.concat(
                        ANCHOR_TX_SELECTOR,
                        bytes32(evidence.meta.l1Height),
                        evidence.meta.l1Hash
                    )
                )
            ) {
                revert ErrProvingAnchorTxInvalidCalldata();
            }

            // Check anchor tx is the 1st tx in the block
            if (
                !proofVerifier.verifyMKP({
                    key: LibRLPWriter.writeUint(0),
                    value: anchorTx,
                    proof: evidence.proofs[zkProofsPerBlock],
                    root: evidence.header.transactionsRoot
                })
            ) {
                revert ErrProvingAnchorTxInvalidTransactionMerkleProof();
            }

            // Check anchor tx does not throw

            LibReceiptDecoder.Receipt memory receipt = LibReceiptDecoder
                .decodeReceipt(anchorReceipt);

            if (receipt.status != 1) {
                revert ErrProvingAnchorTxInvalidReceiptStatus();
            }
            if (
                !proofVerifier.verifyMKP({
                    key: LibRLPWriter.writeUint(0),
                    value: anchorReceipt,
                    proof: evidence.proofs[zkProofsPerBlock + 1],
                    root: evidence.header.receiptsRoot
                })
            ) {
                revert ErrProvingAnchorTxInvalidReceiptMerkleProof();
            }
        }

        // ZK-prove block and mark block proven to be valid.
        _proveBlock({
            state: state,
            config: config,
            resolver: resolver,
            proofVerifier: proofVerifier,
            evidence: evidence,
            target: evidence.meta,
            blockHashOverride: 0
        });
    }

    function proveBlockInvalid(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        AddressResolver resolver,
        uint256 blockId,
        bytes[] calldata inputs
    ) public {
        LibUtils.assertNotHalted(state);

        // Check and decode inputs
        if (inputs.length != 3) revert ErrProvingInvalidInputsLength(3);

        Evidence memory evidence = abi.decode(inputs[0], (Evidence));
        TaikoData.BlockMetadata memory target = abi.decode(
            inputs[1],
            (TaikoData.BlockMetadata)
        );
        bytes calldata invalidateBlockReceipt = inputs[2];

        // Check evidence
        if (evidence.meta.id != blockId) {
            revert ErrProvingBlockIdMismatch();
        }
        if (evidence.proofs.length != 1 + config.zkProofsPerBlock) {
            revert ErrProvingInvalidProofsLength();
        }

        IProofVerifier proofVerifier = IProofVerifier(
            resolver.resolve("proof_verifier", false)
        );

        // Check the event is the first one in the throw-away block
        if (
            !proofVerifier.verifyMKP({
                key: LibRLPWriter.writeUint(0),
                value: invalidateBlockReceipt,
                proof: evidence.proofs[config.zkProofsPerBlock],
                root: evidence.header.receiptsRoot
            })
        ) {
            revert ErrProvingAnchorTxInvalidReceiptMerkleProof();
        }

        // Check the 1st receipt is for an InvalidateBlock tx with
        // a BlockInvalidated event
        LibReceiptDecoder.Receipt memory receipt = LibReceiptDecoder
            .decodeReceipt(invalidateBlockReceipt);
        if (receipt.status != 1) {
            revert ErrProvingAnchorTxInvalidReceiptStatus();
        }
        if (receipt.logs.length != 1) {
            revert ErrProvingAnchorTxInvalidReceiptLogSize();
        }

        {
            LibReceiptDecoder.Log memory log = receipt.logs[0];
            if (
                log.contractAddress !=
                resolver.resolve(config.chainId, "taiko", false)
            ) {
                revert ErrProvingAnchorTxInvalidReceiptDestination();
            }
            if (log.data.length != 0) {
                revert ErrProvingAnchorTxInvalidReceiptLogData();
            }
            if (
                log.topics.length != 2 ||
                log.topics[0] != INVALIDATE_BLOCK_LOG_TOPIC ||
                log.topics[1] != target.txListHash
            ) {
                revert ErrProvingAnchorTxInvalidReceiptLogTopics();
            }
        }

        // ZK-prove block and mark block proven as invalid.
        _proveBlock({
            state: state,
            config: config,
            resolver: resolver,
            proofVerifier: proofVerifier,
            evidence: evidence,
            target: target,
            blockHashOverride: LibUtils.BLOCK_DEADEND_HASH
        });
    }

    function _proveBlock(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        AddressResolver resolver,
        IProofVerifier proofVerifier,
        Evidence memory evidence,
        TaikoData.BlockMetadata memory target,
        bytes32 blockHashOverride
    ) private {
        if (evidence.meta.id != target.id) revert ErrProvingBlockIdMismatch();
        if (evidence.prover == address(0))
            revert ErrProposingZeroProverAddress();

        _checkMetadata({state: state, config: config, meta: target});
        _validateHeaderForMetadata({
            config: config,
            header: evidence.header,
            meta: evidence.meta
        });

        // For alpha-2 testnet, the network allows any address to submit ZKP,
        // but a special prover can skip ZKP verification if the ZKP is empty.

        bool skipZKPVerification;

        // TODO(daniel): remove this special address.
        if (config.enableOracleProver) {
            bytes32 _blockHash = state
            .forkChoices[target.id][evidence.header.parentHash].blockHash;

            if (msg.sender == resolver.resolve("oracle_prover", false)) {
                if (_blockHash != 0) {
                    revert ErrProvingOracleProverMustBeTheFistProver();
                }

                skipZKPVerification = true;
            } else {
                if (_blockHash == 0) {
                    revert ErrProvingCanontProveBeforeOracleProver();
                }
            }
        }

        bytes32 blockHash = evidence.header.hashBlockHeader();

        if (!skipZKPVerification) {
            for (uint256 i = 0; i < config.zkProofsPerBlock; ++i) {
                if (
                    !proofVerifier.verifyZKP({
                        verifierId: string(
                            abi.encodePacked(
                                "plonk_verifier_",
                                i,
                                "_",
                                evidence.circuits[i]
                            )
                        ),
                        zkproof: evidence.proofs[i],
                        blockHash: blockHash,
                        prover: evidence.prover,
                        txListHash: evidence.meta.txListHash
                    })
                ) {
                    revert ErrProvingInvalidZKProof();
                }
            }
        }

        _markBlockProven({
            state: state,
            config: config,
            prover: evidence.prover,
            target: target,
            parentHash: evidence.header.parentHash,
            blockHash: blockHashOverride == 0 ? blockHash : blockHashOverride
        });
    }

    function _markBlockProven(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        address prover,
        TaikoData.BlockMetadata memory target,
        bytes32 parentHash,
        bytes32 blockHash
    ) private {
        TaikoData.ForkChoice storage fc = state.forkChoices[target.id][
            parentHash
        ];

        if (fc.blockHash == 0) {
            // This is the first proof for this block.
            fc.blockHash = blockHash;

            if (!config.enableOracleProver) {
                // If the oracle prover is not enabled
                // we use the first prover's timestamp
                fc.provenAt = uint64(block.timestamp);
            } else {
                // We keep fc.provenAt as 0.
            }
        } else {
            if (fc.provers.length >= config.maxProofsPerForkChoice) {
                revert ErrProvingBlockHasTooManyProofs();
            }

            if (
                fc.provenAt != 0 &&
                block.timestamp >=
                LibUtils.getUncleProofDeadline({
                    state: state,
                    config: config,
                    fc: fc,
                    blockId: target.id
                })
            ) {
                revert ErrProvingTooLateToProveBlock();
            }

            for (uint256 i = 0; i < fc.provers.length; ++i) {
                if (fc.provers[i] == prover) {
                    revert ErrProvingDuplicateProofs();
                }
            }

            if (fc.blockHash != blockHash) {
                // We have a problem here: two proofs are both valid but claims
                // the new block has different hashes.
                if (config.enableOracleProver) {
                    revert ErrProvingConflictingProofs();
                } else {
                    LibUtils.halt(state, true);
                    return;
                }
            }

            if (config.enableOracleProver && fc.provenAt == 0) {
                // If the oracle prover is enabled, we
                // use the second prover's timestamp.
                fc.provenAt = uint64(block.timestamp);
            }
        }

        fc.provers.push(prover);

        emit BlockProven({
            id: target.id,
            parentHash: parentHash,
            blockHash: blockHash,
            timestamp: target.timestamp,
            provenAt: fc.provenAt,
            prover: prover
        });
    }

    function _validateAnchorTxSignature(
        uint256 chainId,
        LibTxDecoder.Tx memory _tx
    ) private view {
        if (_tx.r != LibAnchorSignature.GX && _tx.r != LibAnchorSignature.GX2) {
            revert ErrProvingAnchorTxSignatureInvalidR();
        }

        if (_tx.r == LibAnchorSignature.GX2) {
            (, , uint256 s) = LibAnchorSignature.signTransaction(
                LibTxUtils.hashUnsignedTx(chainId, _tx),
                1
            );
            if (s != 0) {
                revert ErrProvingAnchorTxSignatureInvalidS();
            }
        }
    }

    function _checkMetadata(
        TaikoData.State storage state,
        TaikoData.Config memory config,
        TaikoData.BlockMetadata memory meta
    ) private view {
        if (meta.id <= state.latestVerifiedId || meta.id >= state.nextBlockId) {
            revert ErrProvingBlockIdOutOfRange();
        }
        if (
            state.getProposedBlock(config.maxNumBlocks, meta.id).metaHash !=
            meta.hashMetadata()
        ) {
            revert ErrProvingBlockMetahashMismatch();
        }
    }

    function _validateHeaderForMetadata(
        TaikoData.Config memory config,
        BlockHeader memory header,
        TaikoData.BlockMetadata memory meta
    ) private pure {
        if (
            header.parentHash == 0 ||
            header.beneficiary != meta.beneficiary ||
            header.difficulty != 0 ||
            header.gasLimit != meta.gasLimit + config.anchorTxGasLimit ||
            header.gasUsed == 0 ||
            header.timestamp != meta.timestamp ||
            header.extraData.length != meta.extraData.length ||
            keccak256(header.extraData) != keccak256(meta.extraData) ||
            header.mixHash != meta.mixHash
        ) {
            revert ErrProvingBlockMetahashMismatch();
        }
    }
}
