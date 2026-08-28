package remote

import "testing"

func TestParseMutationStateAndProof(t *testing.T) {
	raw := "SKM2-STATE|2\nrevision=after\nlast_operation=op_123\nlast_kind=apply\nlast_before=before\nlast_after=after\nmanaged=SHA256:x\n--\nkey\n"
	state, err := parseMutationState(raw)
	if err != nil { t.Fatal(err) }
	if !receiptProvesMutation(state, "op_123", "apply", "before") {
		t.Fatalf("receipt should prove mutation: %#v", state)
	}
	if receiptProvesMutation(state, "op_other", "apply", "before") {
		t.Fatal("different operation id unexpectedly proved mutation")
	}
}

func TestReceiptDoesNotProveConcurrentRevision(t *testing.T) {
	state := mutationState{
		Revision: "external",
		LastOperation: "op_123",
		LastKind: "apply",
		LastBefore: "before",
		LastAfter: "after",
	}
	if receiptProvesMutation(state, "op_123", "apply", "before") {
		t.Fatal("receipt must not prove mutation after a subsequent external revision")
	}
}

func TestParseMutationResponseRequiresOperationMatch(t *testing.T) {
	raw := "SKM2-APPLIED|2\noperation=op_123\nrevision=after\n"
	if rev, err := parseMutationResponse(raw, "op_123"); err != nil || rev != "after" {
		t.Fatalf("rev=%q err=%v", rev, err)
	}
	if _, err := parseMutationResponse(raw, "op_other"); err == nil {
		t.Fatal("expected operation mismatch")
	}
}
