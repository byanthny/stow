#!/usr/bin/env swift
import Darwin
import Foundation

// usage: swift scripts/usage.swift <pid> <seconds>
guard CommandLine.arguments.count == 3, let pid = Int32(CommandLine.arguments[1]),
    let seconds = Double(CommandLine.arguments[2]), seconds > 0
else {
    FileHandle.standardError.write(Data("usage: usage.swift <pid> <seconds>\n".utf8))
    exit(2)
}

func read() -> rusage_info_v4 {
    var info = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard status == 0 else {
        FileHandle.standardError.write(Data("proc_pid_rusage failed for \(pid)\n".utf8))
        exit(1)
    }
    return info
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let before = read()
let start = Date()
Thread.sleep(forTimeInterval: seconds)
let after = read()
let elapsed = Date().timeIntervalSince(start)

// CPU times are in Mach absolute time units.
let busy = Double((after.ri_user_time - before.ri_user_time) + (after.ri_system_time - before.ri_system_time))
    * Double(timebase.numer) / Double(timebase.denom)
let cpuSeconds = busy / 1e9
let interrupts = Double(after.ri_interrupt_wkups - before.ri_interrupt_wkups) / elapsed
let packageIdle = Double(after.ri_pkg_idle_wkups - before.ri_pkg_idle_wkups) / elapsed
let footprint = Double(after.ri_phys_footprint) / 1_048_576
print(
    String(
        format: "rusage over %.0f s: cpu %.4f%% (%.1f ms), interrupt wakeups %.2f/s, package idle wakeups %.2f/s, phys footprint %.1f MB",
        elapsed, cpuSeconds / elapsed * 100, cpuSeconds * 1000, interrupts, packageIdle, footprint))
