// Bound each D1 TEXT cell well below 2 MB, including multibyte Chinese notes.
export function splitPayload(payload:string,maxCodeUnits=120000):string[]{
  const chunks:string[]=[];
  for(let start=0;start<payload.length;){let end=Math.min(start+maxCodeUnits,payload.length);const last=payload.charCodeAt(end-1);if(end<payload.length&&last>=0xd800&&last<=0xdbff)end--;chunks.push(payload.slice(start,end));start=end;}
  return chunks;
}
