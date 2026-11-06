//go:build !windows

package main

// The shipped desktop executable is built for Windows. Keep other-platform Go tooling usable.
func watchParent(_ uint32, exited chan<- struct{}) error {
	close(exited)
	return nil
}
