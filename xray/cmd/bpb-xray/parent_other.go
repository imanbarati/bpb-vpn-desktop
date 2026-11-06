//go:build !windows

package main

// The shipped desktop executable is built for Windows. On other platforms, leave
// lifetime management to the caller rather than signaling an immediate parent exit.
func watchParent(_ uint32, _ chan<- struct{}) error {
	return nil
}
