import { useCallback, useRef, useState } from 'react';
import JMuxer from 'jmuxer';
import { H264Demuxer, parseSpsDimensions } from './demux';

// Video frame rate configuration
const VIDEO_FPS = 25;
const FRAME_DURATION_US = 1_000_000 / VIDEO_FPS; // microseconds per frame

export interface VideoDecoderHandle {
  feed: (data: Uint8Array) => void;
  destroy: () => void;
}

async function isWebCodecsSupported(): Promise<boolean> {
  if (typeof VideoDecoder === 'undefined') {
    return false;
  }
  try {
    const result = await VideoDecoder.isConfigSupported({
      codec: 'avc1.42001f',
      codedWidth: 1920,
      codedHeight: 1080,
      hardwareAcceleration: 'prefer-hardware',
      optimizeForLatency: true,
    });
    return result.supported === true;
  } catch {
    return false;
  }
}

function shouldForceJmuxer(): boolean {
  return window.location.hash === '#jmuxer';
}

export function useVideoDecoder(
  log: (msg: string, type?: 'info' | 'error' | 'success') => void,
  canvasRef: React.RefObject<HTMLCanvasElement | null>,
  videoRef: React.RefObject<HTMLVideoElement | null>
) {
  const [useWebCodecs, setUseWebCodecs] = useState(false);
  const canvasCtxRef = useRef<CanvasRenderingContext2D | null>(null);

  // Decoder state refs (not React state to avoid re-renders)
  const jmuxerRef = useRef<JMuxer | null>(null);
  const videoDecoderRef = useRef<VideoDecoder | null>(null);

  // H264 demuxer for WebCodecs (handles raw stream → complete AUs)
  const demuxerRef = useRef<H264Demuxer | null>(null);
  const frameTimestampRef = useRef(0);

  const init = useCallback(async (): Promise<boolean> => {
    const forceJmuxer = shouldForceJmuxer();
    const webCodecsSupported = !forceJmuxer && (await isWebCodecsSupported());

    if (webCodecsSupported && canvasRef.current) {
      try {
        log('Loading WebCodecs decoder...');

        // Show canvas, hide video
        canvasRef.current.style.display = 'block';
        if (videoRef.current) {
          videoRef.current.style.display = 'none';
        }
        canvasCtxRef.current = canvasRef.current.getContext('2d');

        // Create decoder
        videoDecoderRef.current = new VideoDecoder({
          output: (frame) => {
            const ctx = canvasCtxRef.current;
            if (ctx && canvasRef.current) {
              canvasRef.current.width = frame.displayWidth;
              canvasRef.current.height = frame.displayHeight;
              ctx.drawImage(frame, 0, 0, frame.displayWidth, frame.displayHeight);
            }
            frame.close();
          },
          error: (error) => {
            log(`WebCodecs decode error: ${error.message}`, 'error');
            console.error(error);
          },
        });

        // Initialize demuxer
        demuxerRef.current = new H264Demuxer();
        frameTimestampRef.current = 0;

        setUseWebCodecs(true);
        log('Using WebCodecs (low latency mode)', 'success');
        return true;
      } catch (err) {
        log(`WebCodecs init failed, falling back to jMuxer: ${(err as Error).message}`, 'error');
        console.error(err);
        videoDecoderRef.current = null;
        canvasCtxRef.current = null;
        demuxerRef.current = null;
      }
    }

    // Fall back to jMuxer
    if (videoRef.current) {
      try {
        log('Initializing jMuxer...');

        // Show video, hide canvas
        videoRef.current.style.display = 'block';
        if (canvasRef.current) {
          canvasRef.current.style.display = 'none';
        }

        jmuxerRef.current = new JMuxer({
          node: videoRef.current,
          mode: 'video',
          flushingTime: 0,
          clearBuffer: true,
          fps: VIDEO_FPS,
          maxDelay: 0,
          debug: false,
          onReady: () => {
            log('jMuxer ready!', 'success');
          },
          onError: (err: unknown) => {
            log(`jMuxer error: ${err}`, 'error');
          },
        });

        setUseWebCodecs(false);
        log('jMuxer initialized', 'success');
        return true;
      } catch (err) {
        log(`Failed to init jMuxer: ${(err as Error).message}`, 'error');
        return false;
      }
    }

    log('No decoder available', 'error');
    return false;
  }, [log, canvasRef, videoRef]);


  // Track if decoder is configured to avoid async overhead per frame
  const isConfiguredRef = useRef(false);
  // Track if we need to wait for a keyframe (after configure or error)
  const needKeyframeRef = useRef(true);

  const feed = useCallback((data: Uint8Array) => {
    if (videoDecoderRef.current && demuxerRef.current) {
      // Use demuxer to extract complete frames from raw H264 stream
      const { frames } = demuxerRef.current.feed(data);

      // Process each complete frame synchronously to maintain order
      for (const frame of frames) {
        if (!videoDecoderRef.current) break;

        // Check if already configured (fast path)
        if (!isConfiguredRef.current) {
          // Need to configure - do it synchronously if possible
          const sps = demuxerRef.current.getSps();
          if (!sps) {
            // console.log('[VideoDecoder] Skipping frame - no SPS yet');
            continue;
          }

          const parsed = parseSpsDimensions(sps);
          if (!parsed) {
            console.error('[VideoDecoder] Failed to parse SPS');
            continue;
          }

          try {
            videoDecoderRef.current.configure({
              codec: parsed.codec,
              codedWidth: parsed.width,
              codedHeight: parsed.height,
              hardwareAcceleration: 'prefer-hardware',
              optimizeForLatency: true,
            });
            isConfiguredRef.current = true;
            needKeyframeRef.current = true; // Need keyframe after configure
            console.log(`[VideoDecoder] Configured: ${parsed.codec} (${parsed.width}x${parsed.height})`);
          } catch (err) {
            console.error('[VideoDecoder] Configure failed:', err);
            continue;
          }
        }

        // After configure, we must wait for a keyframe
        if (needKeyframeRef.current && !frame.isKeyframe) {
          // console.log('[VideoDecoder] Waiting for keyframe...');
          continue;
        }

        if (frame.isKeyframe) {
          needKeyframeRef.current = false;
        }

        // Decoder is configured, decode synchronously
        const timestamp = frameTimestampRef.current;
        frameTimestampRef.current += FRAME_DURATION_US;

        try {
          const chunk = new EncodedVideoChunk({
            type: frame.isKeyframe ? 'key' : 'delta',
            timestamp,
            data: frame.data,
          });
          videoDecoderRef.current.decode(chunk);
        } catch (err) {
          console.error('WebCodecs decode failed', err);
          // On decode error, wait for next keyframe
          needKeyframeRef.current = true;
        }
      }
    } else if (jmuxerRef.current) {
      jmuxerRef.current.feed({ video: data });
    }
  }, []);

  const destroy = useCallback(() => {
    if (videoDecoderRef.current) {
      try {
        videoDecoderRef.current.close();
      } catch { /* ignore */ }
      videoDecoderRef.current = null;
    }

    canvasCtxRef.current = null;
    frameTimestampRef.current = 0;
    isConfiguredRef.current = false;
    needKeyframeRef.current = true;

    if (demuxerRef.current) {
      demuxerRef.current.reset();
      demuxerRef.current = null;
    }

    if (jmuxerRef.current) {
      try {
        jmuxerRef.current.destroy();
      } catch { /* ignore */ }
      jmuxerRef.current = null;
    }

    setUseWebCodecs(false);
  }, []);

  return {
    useWebCodecs,
    init,
    feed,
    destroy,
  };
}
