//go:build windows

package main

import (
	"fmt"
	"syscall"
)

// watchParent keeps a kernel handle to the owning desktop process. Unlike watching a PID
// number, the handle cannot accidentally attach to a later process that reuses that PID.
func watchParent(pid uint32, exited chan<- struct{}) error {
	handle, err := syscall.OpenProcess(0x00100000, false, pid) // SYNCHRONIZE
	if err != nil {
		return fmt.Errorf("OpenProcess(%d): %w", pid, err)
	}
	go func() {
		defer syscall.CloseHandle(handle)
		_, _ = syscall.WaitForSingleObject(handle, 0xffffffff) // INFINITE
		close(exited)
	}()
	return nil
}
