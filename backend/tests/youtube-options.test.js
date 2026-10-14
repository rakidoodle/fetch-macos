import { test } from 'node:test';
import assert from 'node:assert/strict';
import { youtubeOptions, youtubeFormatArgs } from '../server/manager.js';
test('YouTube resolution and container are independent and correctly reach yt-dlp', () => {
  for (const resolution of ['best', '2160', '1440', '1080', '720', '480', '360', '240', '144']) {
    for (const format of ['mp4', 'webm', 'mkv']) {
      const options = { mode: 'video', resolution, format };
      assert.equal(youtubeOptions(options).resolution, resolution);
      assert.equal(youtubeOptions(options).format, format);
      const args = youtubeFormatArgs(options);
      assert.ok(args.includes(format));
      if (resolution !== 'best') assert.ok(args[1].includes(`height<=${resolution}`));
    }
  }
});
test('Every supported audio format gets extraction and invalid mode combinations fail', () => {
  for (const format of ['mp3', 'm4a', 'flac', 'wav', 'opus']) {
    const args = youtubeFormatArgs({ mode: 'audio', format });
    assert.ok(args.includes('--extract-audio')); assert.equal(args.at(-1), format);
  }
  assert.throws(() => youtubeOptions({ mode: 'video', format: 'mp3' }));
  assert.throws(() => youtubeOptions({ mode: 'audio', format: 'mp4' }));
  assert.throws(() => youtubeOptions({ mode: 'video', resolution: '999' }));
});
