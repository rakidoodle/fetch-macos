import { createVideoFixture } from '../backend/tests/video-fixture.js';
const fixture=await createVideoFixture();
console.log(JSON.stringify({base:fixture.base}));
async function stop(){await fixture.close();process.exit(0);}
process.on('SIGTERM',stop);process.on('SIGINT',stop);
