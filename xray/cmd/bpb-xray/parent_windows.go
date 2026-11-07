//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
)

const winInetSettingsKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`

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

type registryValue struct {
	Type string `json:"type"`
	Data string `json:"data"`
}

// restoreProxyBackup runs inside Xray when the Flutter parent disappears. Dart cannot
// restore WinINet settings after its own process has been terminated, so the child does it.
func restoreProxyBackup(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // The app may have exited before it applied the proxy.
		}
		return err
	}
	values := map[string]registryValue{}
	if err := json.Unmarshal(data, &values); err != nil {
		return fmt.Errorf("decode proxy backup: %w", err)
	}
	for _, name := range []string{"ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL", "AutoDetect"} {
		value, ok := values[name]
		var command *exec.Cmd
		if ok && value.Type != "" {
			command = exec.Command("reg.exe", "add", winInetSettingsKey, "/v", name, "/t", value.Type, "/d", value.Data, "/f")
		} else {
			command = exec.Command("reg.exe", "delete", winInetSettingsKey, "/v", name, "/f")
		}
		if output, err := command.CombinedOutput(); err != nil && ok {
			return fmt.Errorf("restore %s: %w: %s", name, err, output)
		}
	}
	refresh := `$src = @"
using System;
using System.Runtime.InteropServices;
public static class BpbWinInet {
 [DllImport("wininet.dll", SetLastError=true)]
 public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
}
"@
Add-Type -TypeDefinition $src
if (-not [BpbWinInet]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0)) { throw 'INTERNET_OPTION_SETTINGS_CHANGED failed' }
if (-not [BpbWinInet]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0)) { throw 'INTERNET_OPTION_REFRESH failed' }
`
	if output, err := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", refresh).CombinedOutput(); err != nil {
		return fmt.Errorf("refresh WinINet settings: %w: %s", err, output)
	}
	_ = os.Remove(path)
	_ = os.Remove(filepath.Join(filepath.Dir(path), "session.json"))
	return nil
}
