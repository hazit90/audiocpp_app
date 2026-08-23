import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// How many threads to hand the CPU backend.
///
/// This is not `numberOfProcessors` for a reason. ggml synchronises its worker
/// threads at every graph node with a spin-wait barrier, so a graph runs at the
/// speed of its slowest thread. On a hybrid CPU — every Intel Core Ultra, and
/// Alder Lake onward generally — scheduling work onto the efficiency cores
/// therefore makes the whole generation slower, not faster: the P-cores finish
/// their share and burn cycles waiting for the E-cores at every single node.
///
/// So on Windows we ask the OS which cores are the fast ones and use only
/// those. Everywhere else the old heuristic stands, which is correct for the
/// homogeneous CPUs macOS runs on.
///
/// Set `AUDIOCPP_THREADS` to override, which is the honest way to tune this:
/// the right number is measurable and the wrong number is only a guess.
int recommendedThreadCount() {
  final override = _threadsFromEnvironment();
  if (override != null) {
    return override;
  }

  if (Platform.isWindows) {
    final performanceCores = _windowsPerformanceCoreCount();
    if (performanceCores != null && performanceCores > 0) {
      return performanceCores;
    }
  }

  // Leave a couple of cores for the UI and the OS.
  final cores = Platform.numberOfProcessors;
  return cores > 4 ? cores - 2 : cores;
}

int? _threadsFromEnvironment() {
  final raw = Platform.environment['AUDIOCPP_THREADS'];
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final parsed = int.tryParse(raw.trim());
  if (parsed == null || parsed < 1) {
    debugPrint('AUDIOCPP_THREADS="$raw" is not a positive integer, ignoring.');
    return null;
  }
  return parsed;
}

// --- Windows hybrid-core detection -------------------------------------------

const int _relationProcessorCore = 0;

// Field offsets into SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX. Hand-written
// because the record is variable-length — GROUP_AFFINITY[] tails it — so it
// cannot be expressed as an ffi.Struct and has to be walked by its own Size.
//
//   0  DWORD Relationship
//   4  DWORD Size
//   8  BYTE  Processor.Flags
//   9  BYTE  Processor.EfficiencyClass
//  10  BYTE  Processor.Reserved[20]
//  30  WORD  Processor.GroupCount
//  32  GROUP_AFFINITY Processor.GroupMask[]
const int _offsetSize = 4;
const int _offsetEfficiencyClass = 9;

typedef _GetLogicalProcessorInformationExNative = Int32 Function(
    Int32 relationshipType, Pointer<Uint8> buffer, Pointer<Uint32> returnedLength);
typedef _GetLogicalProcessorInformationExDart = int Function(
    int relationshipType, Pointer<Uint8> buffer, Pointer<Uint32> returnedLength);

/// Number of physical performance cores, or null if we could not tell.
///
/// One `RelationProcessorCore` record is emitted per *physical* core, so
/// counting records already excludes hyperthreads — which is what we want.
/// Windows reports relative speed as `EfficiencyClass`, higher being faster, so
/// the performance cores are the ones sharing the maximum value. A CPU with no
/// hybrid topology reports a single class, and every core qualifies.
int? _windowsPerformanceCoreCount() {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final getInfo = kernel32.lookupFunction<_GetLogicalProcessorInformationExNative,
        _GetLogicalProcessorInformationExDart>('GetLogicalProcessorInformationEx');

    final lengthPtr = calloc<Uint32>();
    try {
      // First call sizes the buffer; it is expected to fail.
      getInfo(_relationProcessorCore, nullptr, lengthPtr);
      final length = lengthPtr.value;
      if (length == 0) {
        return null;
      }

      final buffer = calloc<Uint8>(length);
      try {
        if (getInfo(_relationProcessorCore, buffer, lengthPtr) == 0) {
          return null;
        }

        final byteData = buffer.asTypedList(length).buffer.asByteData();
        final efficiencyClasses = <int>[];
        var offset = 0;
        while (offset + _offsetEfficiencyClass < length) {
          final size = byteData.getUint32(offset + _offsetSize, Endian.little);
          // A zero or overrunning size would spin here forever.
          if (size == 0 || offset + size > length) {
            break;
          }
          efficiencyClasses.add(byteData.getUint8(offset + _offsetEfficiencyClass));
          offset += size;
        }

        if (efficiencyClasses.isEmpty) {
          return null;
        }
        final fastest = efficiencyClasses.reduce((a, b) => a > b ? a : b);
        return efficiencyClasses.where((c) => c == fastest).length;
      } finally {
        calloc.free(buffer);
      }
    } finally {
      calloc.free(lengthPtr);
    }
  } on Object catch (error) {
    // Detection is an optimisation, never a requirement: any failure just
    // means we fall back to the portable heuristic.
    debugPrint('Could not read CPU topology, falling back to core count: $error');
    return null;
  }
}
