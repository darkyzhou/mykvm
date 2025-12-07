/**
 * H264 Annex-B demuxer utilities
 * Adapted from jmuxer (https://github.com/nicholashamilton/jmuxer)
 * License: MIT
 */

// ---------------------------------------------------------------------------
// NAL unit types
// ---------------------------------------------------------------------------

export const NAL_TYPE = {
  NDR: 1,  // Non-IDR slice
  IDR: 5,  // IDR slice
  SEI: 6,  // Supplemental enhancement information
  SPS: 7,  // Sequence parameter set
  PPS: 8,  // Picture parameter set
  AUD: 9,  // Access unit delimiter
} as const;

/**
 * Check if NAL type is VCL (Video Coding Layer) - actual video data
 */
export function isVCL(nalType: number): boolean {
  return nalType === NAL_TYPE.IDR || nalType === NAL_TYPE.NDR;
}

// ---------------------------------------------------------------------------
// Bit reader for Exp-Golomb decoding
// ---------------------------------------------------------------------------

export class BitReader {
  private byteOffset = 0;
  private bitOffset = 0;
  private readonly data: Uint8Array;

  constructor(data: Uint8Array) {
    this.data = data;
  }

  readBits(bits: number): number {
    let result = 0;
    while (bits > 0) {
      if (this.byteOffset >= this.data.length) {
        throw new Error('BitReader: out of data');
      }
      const current = this.data[this.byteOffset];
      const remaining = 8 - this.bitOffset;
      const take = Math.min(bits, remaining);
      const shift = remaining - take;
      result = (result << take) | ((current >> shift) & ((1 << take) - 1));
      this.bitOffset += take;
      if (this.bitOffset === 8) {
        this.bitOffset = 0;
        this.byteOffset++;
      }
      bits -= take;
    }
    return result;
  }

  /**
   * Read unsigned Exp-Golomb coded value
   */
  readUE(): number {
    let zeros = 0;
    while (this.readBits(1) === 0) {
      zeros++;
      if (zeros > 32) {
        throw new Error('BitReader: invalid Exp-Golomb code');
      }
    }
    const value = zeros > 0 ? this.readBits(zeros) : 0;
    return (1 << zeros) - 1 + value;
  }
}

// ---------------------------------------------------------------------------
// NAL unit extraction (from jmuxer H264Parser.extractNALu)
// ---------------------------------------------------------------------------

/**
 * Extract NAL units from Annex-B byte stream.
 * Returns array of complete NAL units and any remaining incomplete data.
 */
export function extractNALu(buffer: Uint8Array): [Uint8Array[], Uint8Array | null] {
  let i = 0;
  const length = buffer.byteLength;
  const result: Uint8Array[] = [];
  let lastIndex = 0;
  let zeroCount = 0;

  while (i < length) {
    const value = buffer[i++];

    if (value === 0) {
      zeroCount++;
    } else if (value === 1 && zeroCount >= 2) {
      const startCodeLength = zeroCount + 1;

      if (lastIndex !== i - startCodeLength) {
        result.push(buffer.subarray(lastIndex, i - startCodeLength));
      }

      lastIndex = i;
      zeroCount = 0;
    } else {
      zeroCount = 0;
    }
  }

  // Remaining data after last start code
  let left: Uint8Array | null = null;
  if (lastIndex < length) {
    left = buffer.subarray(lastIndex, length);
  }

  return [result, left];
}

// ---------------------------------------------------------------------------
// Frame boundary detection (from jmuxer NALU264.isFirstSlice)
// ---------------------------------------------------------------------------

/**
 * Check if this NAL unit is the first slice of a new frame.
 * Only applicable to VCL NAL units (IDR=5, non-IDR=1).
 */
export function isFirstSliceInFrame(nal: Uint8Array): boolean {
  const nalType = nal[0] & 0x1f;
  if (!isVCL(nalType)) {
    return false;
  }

  try {
    // Parse slice header to get first_mb_in_slice
    // Skip NAL header byte, then read first_mb_in_slice (Exp-Golomb)
    const br = new BitReader(nal.subarray(1));
    const firstMbInSlice = br.readUE();
    return firstMbInSlice === 0;
  } catch {
    // If parsing fails, assume it's a new frame to be safe
    return true;
  }
}

// ---------------------------------------------------------------------------
// Utility functions
// ---------------------------------------------------------------------------

/**
 * Remove emulation prevention bytes (0x03) from NAL unit
 */
export function removeEmulationPrevention(bytes: Uint8Array): Uint8Array {
  const out: number[] = [];
  for (let i = 0; i < bytes.length; i++) {
    if (i + 2 < bytes.length && bytes[i] === 0x00 && bytes[i + 1] === 0x00 && bytes[i + 2] === 0x03) {
      out.push(0x00, 0x00);
      i += 2;
      continue;
    }
    out.push(bytes[i]);
  }
  return new Uint8Array(out);
}

/**
 * Concatenate multiple Uint8Arrays
 */
function concatArrays(...arrays: Uint8Array[]): Uint8Array {
  const totalLength = arrays.reduce((acc, arr) => acc + arr.length, 0);
  const result = new Uint8Array(totalLength);
  let offset = 0;
  for (const arr of arrays) {
    result.set(arr, offset);
    offset += arr.length;
  }
  return result;
}

/**
 * Assemble NAL units into an Access Unit with Annex-B start codes
 */
export function assembleAU(nals: Uint8Array[]): Uint8Array {
  const startCode = new Uint8Array([0x00, 0x00, 0x00, 0x01]);
  const parts: Uint8Array[] = [];
  for (const nal of nals) {
    parts.push(startCode, nal);
  }
  return concatArrays(...parts);
}

// ---------------------------------------------------------------------------
// SPS parsing
// ---------------------------------------------------------------------------

function hex2(value: number): string {
  return value.toString(16).padStart(2, '0');
}

export interface ParsedSps {
  codec: string;
  width: number;
  height: number;
}

/**
 * Parse SPS NAL unit to extract codec string and dimensions
 */
export function parseSpsDimensions(spsNal: Uint8Array): ParsedSps | null {
  // Drop NAL header, remove emulation prevention, then parse RBSP
  const rbsp = removeEmulationPrevention(spsNal.subarray(1));
  const br = new BitReader(rbsp);

  try {
    const profileIdc = br.readBits(8);
    const constraintSetFlags = br.readBits(8);
    const levelIdc = br.readBits(8);
    const codec = `avc1.${hex2(profileIdc)}${hex2(constraintSetFlags)}${hex2(levelIdc)}`;

    br.readUE(); // seq_parameter_set_id

    const highProfileIds = new Set([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]);
    if (highProfileIds.has(profileIdc)) {
      const chromaFormatIdc = br.readUE();
      if (chromaFormatIdc === 3) {
        br.readBits(1); // separate_colour_plane_flag
      }
      br.readUE(); // bit_depth_luma_minus8
      br.readUE(); // bit_depth_chroma_minus8
      br.readBits(1); // qpprime_y_zero_transform_bypass_flag
      const seqScalingMatrixPresentFlag = br.readBits(1);
      if (seqScalingMatrixPresentFlag) {
        const scalingListCount = chromaFormatIdc !== 3 ? 8 : 12;
        for (let i = 0; i < scalingListCount; i++) {
          const present = br.readBits(1);
          if (present) {
            const size = i < 6 ? 16 : 64;
            let lastScale = 8;
            let nextScale = 8;
            for (let j = 0; j < size; j++) {
              if (nextScale !== 0) {
                const deltaScale = br.readUE();
                nextScale = (lastScale + deltaScale + 256) % 256;
              }
              lastScale = nextScale === 0 ? lastScale : nextScale;
            }
          }
        }
      }
    }

    br.readUE(); // log2_max_frame_num_minus4
    const picOrderCntType = br.readUE();
    if (picOrderCntType === 0) {
      br.readUE(); // log2_max_pic_order_cnt_lsb_minus4
    } else if (picOrderCntType === 1) {
      br.readBits(1); // delta_pic_order_always_zero_flag
      br.readUE(); // offset_for_non_ref_pic
      br.readUE(); // offset_for_top_to_bottom_field
      const numRefFramesInPicOrderCntCycle = br.readUE();
      for (let i = 0; i < numRefFramesInPicOrderCntCycle; i++) {
        br.readUE();
      }
    }

    br.readUE(); // max_num_ref_frames
    br.readBits(1); // gaps_in_frame_num_value_allowed_flag

    const picWidthInMbsMinus1 = br.readUE();
    const picHeightInMapUnitsMinus1 = br.readUE();
    const frameMbsOnlyFlag = br.readBits(1);
    if (!frameMbsOnlyFlag) {
      br.readBits(1); // mb_adaptive_frame_field_flag
    }
    br.readBits(1); // direct_8x8_inference_flag

    let frameCropLeft = 0;
    let frameCropRight = 0;
    let frameCropTop = 0;
    let frameCropBottom = 0;
    const frameCroppingFlag = br.readBits(1);
    if (frameCroppingFlag) {
      frameCropLeft = br.readUE();
      frameCropRight = br.readUE();
      frameCropTop = br.readUE();
      frameCropBottom = br.readUE();
    }

    const width = (picWidthInMbsMinus1 + 1) * 16;
    const heightInMapUnits = picHeightInMapUnitsMinus1 + 1;
    const frameHeight = (2 - frameMbsOnlyFlag) * heightInMapUnits * 16;

    const cropUnitX = 1; // assume 4:2:0
    const cropUnitY = frameMbsOnlyFlag ? 2 : 4;
    const croppedWidth = width - (frameCropLeft + frameCropRight) * cropUnitX * 2;
    const croppedHeight = frameHeight - (frameCropTop + frameCropBottom) * cropUnitY * 2;

    return { codec, width: croppedWidth, height: croppedHeight };
  } catch (err) {
    console.error('Failed to parse SPS', err);
    return null;
  }
}

// ---------------------------------------------------------------------------
// H264 Demuxer class (combines all logic from jmuxer)
// ---------------------------------------------------------------------------

export interface DemuxedFrame {
  data: Uint8Array;
  isKeyframe: boolean;
}

export interface DemuxResult {
  frames: DemuxedFrame[];
  sps: Uint8Array | null;
  pps: Uint8Array | null;
}

interface PendingUnits {
  nals: Uint8Array[];
  hasIdr: boolean;
  hasVcl: boolean;
}

/**
 * H264 Demuxer - extracts complete Access Units from raw H264 Annex-B stream
 *
 * Adapted from jmuxer's H264Remuxer.getVideoFrames() logic
 */
export class H264Demuxer {
  private remainingData: Uint8Array = new Uint8Array(0);
  private pendingUnits: PendingUnits = { nals: [], hasIdr: false, hasVcl: false };
  private sps: Uint8Array | null = null;
  private pps: Uint8Array | null = null;

  /**
   * Feed raw H264 data and get back complete frames
   */
  feed(data: Uint8Array): DemuxResult {
    // Concatenate remaining data with new data
    const combined = this.remainingData.length > 0
      ? concatArrays(this.remainingData, data)
      : data;

    // Extract NAL units
    const [nals, remaining] = extractNALu(combined);
    this.remainingData = remaining ?? new Uint8Array(0);

    const frames: DemuxedFrame[] = [];
    let currentSps: Uint8Array | null = null;
    let currentPps: Uint8Array | null = null;

    // Restore pending state
    let units = this.pendingUnits.nals;
    let hasIdr = this.pendingUnits.hasIdr;
    let hasVcl = this.pendingUnits.hasVcl;

    for (const nal of nals) {
      if (nal.length === 0) continue;

      const nalType = nal[0] & 0x1f;

      // Extract SPS/PPS
      if (nalType === NAL_TYPE.SPS) {
        this.sps = nal;
        currentSps = nal;
      } else if (nalType === NAL_TYPE.PPS) {
        this.pps = nal;
        currentPps = nal;
      }

      const nalIsVcl = isVCL(nalType);
      const isKeyframe = nalType === NAL_TYPE.IDR;

      // Frame boundary detection (from jmuxer getVideoFrames)
      // New frame starts when:
      // 1. We already have VCL NALs, AND
      // 2. Current NAL is either first slice of a new frame OR non-VCL
      if (units.length > 0 && hasVcl && (isFirstSliceInFrame(nal) || !nalIsVcl)) {
        // Emit the previous frame
        frames.push({
          data: assembleAU(units),
          isKeyframe: hasIdr,
        });
        units = [];
        hasIdr = false;
        hasVcl = false;
      }

      // Skip AUD and SEI NALs (not needed for decoding)
      if (nalType === NAL_TYPE.AUD || nalType === NAL_TYPE.SEI) {
        continue;
      }

      units.push(nal);
      hasIdr = hasIdr || isKeyframe;
      hasVcl = hasVcl || nalIsVcl;
    }

    // IMPORTANT: Since backend sends one complete encoded frame per WebSocket message,
    // we should flush pending units at the end of each feed() call.
    // The original logic waits for the next frame's first slice to detect frame boundary,
    // which causes a 1-frame delay.
    if (units.length > 0 && hasVcl) {
      frames.push({
        data: assembleAU(units),
        isKeyframe: hasIdr,
      });
      units = [];
      hasIdr = false;
      hasVcl = false;
    }

    // Save pending units for next feed (should be empty now for complete frames)
    this.pendingUnits = { nals: units, hasIdr, hasVcl };

    return {
      frames,
      sps: currentSps,
      pps: currentPps,
    };
  }

  /**
   * Flush any remaining pending units as a frame
   */
  flush(): DemuxResult {
    const frames: DemuxedFrame[] = [];

    if (this.pendingUnits.nals.length > 0 && this.pendingUnits.hasVcl) {
      frames.push({
        data: assembleAU(this.pendingUnits.nals),
        isKeyframe: this.pendingUnits.hasIdr,
      });
    }

    this.pendingUnits = { nals: [], hasIdr: false, hasVcl: false };

    return {
      frames,
      sps: null,
      pps: null,
    };
  }

  /**
   * Get the last seen SPS
   */
  getSps(): Uint8Array | null {
    return this.sps;
  }

  /**
   * Get the last seen PPS
   */
  getPps(): Uint8Array | null {
    return this.pps;
  }

  /**
   * Reset all state
   */
  reset(): void {
    this.remainingData = new Uint8Array(0);
    this.pendingUnits = { nals: [], hasIdr: false, hasVcl: false };
    this.sps = null;
    this.pps = null;
  }
}

