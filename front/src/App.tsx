import { Route, Routes } from 'react-router-dom';
import ErrorBanner from './components/ErrorBanner';
import Inicio from './pages/Inicio';
import Registro from './pages/Registro';
import Login from './pages/Login';

export default function App() {
  return (
    <>
      <ErrorBanner />
      <Routes>
        <Route path="/" element={<Inicio />} />
        <Route path="/registro" element={<Registro />} />
        <Route path="/login" element={<Login />} />
        <Route path="*" element={<Inicio />} />
      </Routes>
    </>
  );
}
