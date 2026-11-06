import type {Document} from './document';

export function lyricFilename(title: string) {
  const name = Array.from(title.replace(/[<>:"/\\|?*\u0000-\u001f]/g, '-').trim()).slice(0, 120).join('').replace(/[. ]+$/, '');
  return `${name || 'Lyrics'}.png`;
}

/** Match the 720pt macOS SharedLyricArtwork at Retina resolution. */
export async function lyricArtwork(title: string, target: string, lines: Document['lines']) {
  await document.fonts.ready;
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  if (!ctx) throw Error('Image export is unavailable.');
  const sans = '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif';
  const titleFont = '500 46px Georgia, serif';
  const originalFont = `500 29px ${sans}`, translatedFont = `25px ${sans}`;
  function wrap(text: string, font: string, width: number) {
    ctx!.font = font;
    const rows: string[] = [];
    for (const paragraph of text.split('\n')) {
      let row = '';
      for (const {segment} of new Intl.Segmenter(undefined, {granularity:'word'}).segment(paragraph)) {
        if (row && ctx!.measureText(row + segment).width > width) { rows.push(row.trimEnd()); row = ''; }
        for (const {segment: char} of new Intl.Segmenter(undefined, {granularity:'grapheme'}).segment(segment)) {
          if (row && ctx!.measureText(row + char).width > width) { rows.push(row); row = ''; }
          if (row || char.trim()) row += char;
        }
      }
      rows.push(row);
    }
    return rows;
  }
  const heading = wrap(title || 'A song, reimagined.', titleFont, 624);
  const content = lines.map(line => ({original:wrap(line.original, originalFont, 552), translated:line.translated ? wrap(line.translated, translatedFont, 552) : []}));
  const cardTop = 48 + 36 + 36 + heading.length * 55 + 36;
  const cardHeight = 72 + 64 + content.reduce((height, line) => height + line.original.length * 41 + (line.translated.length ? 12 + line.translated.length * 37 : 0), 0) + Math.max(0, content.length - 1) * 30;
  const height = cardTop + cardHeight + 36 + 20 + 48;
  if (height * 2 > 16000) throw Error('Select fewer lines to export one image.');
  canvas.width = 1440; canvas.height = Math.ceil(height * 2); ctx.scale(2, 2);
  ctx.fillStyle = '#040b20'; ctx.fillRect(0, 0, 720, height);
  const glow = (x:number,y:number,r:number,color:string) => {const g=ctx.createRadialGradient(x,y,0,x,y,r);g.addColorStop(0,color);g.addColorStop(1,'transparent');ctx.fillStyle=g;ctx.fillRect(0,0,720,height);};
  glow(720, 0, 650, '#1f5291a6'); glow(0, height, 450, '#402b6e59');
  ctx.textBaseline = 'top';
  const blue = '#9cc7ff';
  ctx.strokeStyle = blue; ctx.lineWidth = 2; ctx.lineCap = 'round';
  [10,22,30,16,24,8].forEach((h,i) => {ctx.beginPath();ctx.moveTo(49+i*5,66-h/2);ctx.lineTo(49+i*5,66+h/2);ctx.stroke();});
  ctx.font = `600 12px ${sans}`; ctx.fillStyle = blue;
  ctx.fillText('L Y R I C S T U D I O', 88, 60);
  if (target) {
    ctx.font = `500 13px ${sans}`;
    let badge = target;
    while (ctx.measureText(badge).width > 220) badge = Array.from(badge).slice(0,-2).join('') + '…';
    const width = ctx.measureText(badge).width + 32;
    ctx.beginPath();ctx.roundRect(672-width,48,width,36,18);ctx.fillStyle='#9cc7ff1a';ctx.fill();ctx.strokeStyle='#9cc7ff40';ctx.lineWidth=1;ctx.stroke();
    ctx.fillStyle=blue;ctx.fillText(badge,688-width,59);
  }
  function draw(rows:string[], font:string, color:string, x:number, y:number, step:number) {
    ctx!.font=font;ctx!.fillStyle=color;
    for (const row of rows) {ctx!.fillText(row,x,y);y+=step;}
    return y;
  }
  draw(heading,titleFont,'#f0f5ff',48,120,55);
  const glass=ctx.createLinearGradient(48,cardTop,672,cardTop+cardHeight);glass.addColorStop(0,'#ffffff17');glass.addColorStop(1,'#ffffff06');
  ctx.beginPath();ctx.roundRect(48,cardTop,624,cardHeight,28);ctx.fillStyle=glass;ctx.fill();
  const border=ctx.createLinearGradient(48,cardTop,672,cardTop+cardHeight);border.addColorStop(0,'#ffffff40');border.addColorStop(1,'#ffffff12');ctx.strokeStyle=border;ctx.lineWidth=1;ctx.stroke();
  draw(['“'],'54px Georgia, serif','#9cc7ffa6',84,cardTop+30,54);
  let y=cardTop+100;
  for (const line of content) {
    y=draw(line.original,originalFont,'#f0f5ff',84,y,41);
    if(line.translated.length)y=draw(line.translated,translatedFont,blue,84,y+12,37);
    y+=30;
  }
  y=cardTop+cardHeight+36;
  ctx.fillStyle='#9cc7ff73';ctx.fillRect(48,y+9,28,1);
  draw(['W O R D S  A C R O S S  W O R L D S'],`500 10px ${sans}`,'#9cc7ffbf',88,y+3,20);
  draw(['✦'],`22px ${sans}`,'#9cc7ffbf',652,y-3,22);
  return new Promise<Blob>((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(Error('PNG export failed.')),'image/png'));
}
