import { fetchWithoutRedirects } from '../src/http';

export default {
  async fetch(request:Request):Promise<Response> {
    try {
      const response=await fetchWithoutRedirects('https://provider.test'+new URL(request.url).pathname,{
        method:'POST',headers:{Authorization:'Bearer test-only','Content-Type':'application/json'},body:'{}',
      });
      return Response.json({status:response.status,body:await response.text()});
    }catch(error){return Response.json({error:error instanceof Error?error.message:'Unknown error'},{status:502});}
  },
};
