package sp1

/*
#cgo darwin LDFLAGS: ./lib/libsp1_verifier.a
#cgo linux LDFLAGS: ./lib/libsp1_verifier.a -ldl -lrt -lm

#include "lib/sp1.h"
*/
import "C"
import (
	"unsafe"
)

const MAX_PROOF_SIZE = 1024 * 1024

func VerifySp1Proof(proofBuffer [MAX_PROOF_SIZE]byte, proofLen uint) bool {
	proofPtr := (*C.uchar)(unsafe.Pointer(&proofBuffer[0]))
	return (bool)(C.verify_sp1_proof_ffi(proofPtr, (C.uint)(proofLen)))
}
