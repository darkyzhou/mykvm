import { createRoot } from 'react-dom/client';
import App from './App';

// Remove StrictMode to avoid double WebSocket connections during development
createRoot(document.getElementById('root')!).render(<App />);
