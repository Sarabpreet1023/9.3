import React, {useEffect, useState} from 'react';

function App(){
  const [backend, setBackend] = useState(null);

  useEffect(()=> {
    fetch('/api/health')
      .then(r => r.json())
      .then(setBackend)
      .catch(e => setBackend({ error: e.message }));
  }, []);

  return (
    <div style={{ textAlign: 'center', marginTop: 80 }}>
      <h1>Full Stack App on AWS</h1>
      <p>Frontend served by Nginx. Backend behind ALB.</p>
      <pre>{JSON.stringify(backend, null, 2)}</pre>
    </div>
  );
}

export default App;
