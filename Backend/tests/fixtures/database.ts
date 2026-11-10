import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';

export function database(schema=readFileSync(new URL('../../schema.sql',import.meta.url),'utf8')) {
  const sqlite=new DatabaseSync(':memory:');
  sqlite.exec(schema);
  class Statement {
    sql:string;args:any[]=[];
    constructor(sql:string){this.sql=sql;}
    bind(...args:any[]){const result=new Statement(this.sql);result.args=args;return result;}
    async first<T>():Promise<T|null>{return sqlite.prepare(this.sql).get(...this.args) as T||null;}
    async all<T>(){return {results:sqlite.prepare(this.sql).all(...this.args) as T[],success:true};}
    async run(){const result=sqlite.prepare(this.sql).run(...this.args);return {success:true,meta:{changes:Number(result.changes)}};}
  }
  return {
    sqlite,
    DB:{
      prepare:(sql:string)=>new Statement(sql),
      async batch(statements:Statement[]){
        sqlite.exec('BEGIN');
        try {const result=[];for(const statement of statements)result.push(await statement.run());sqlite.exec('COMMIT');return result;}
        catch(error){sqlite.exec('ROLLBACK');throw error;}
      }
    } as unknown as D1Database
  };
}
