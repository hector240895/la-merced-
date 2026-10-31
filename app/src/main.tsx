import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import './index.css';
import App from './App';
import { ProveedorAvisos } from './componentes/Aviso';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ProveedorAvisos>
      <App />
    </ProveedorAvisos>
  </StrictMode>,
);
