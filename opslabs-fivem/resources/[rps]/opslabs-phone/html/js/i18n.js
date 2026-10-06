'use strict';

/* =====================================================================
   Language & region
   - Dates/times use Intl with the chosen locale (12/24h per region).
   - Temperature, distance, speed, weight, time format, date format and
     first day of week are each the player's own choice (Units & Formats),
     independent of language and region.
   - UI text is translated by swapping exact English strings for the chosen
     language as screens render (user content such as messages is skipped).
   ===================================================================== */

const LANGUAGES = [
    { id: 'en', name: 'English', native: 'English' },
    { id: 'es', name: 'Spanish', native: 'Español' },
    { id: 'fr', name: 'French', native: 'Français' },
    { id: 'de', name: 'German', native: 'Deutsch' },
    { id: 'pt', name: 'Portuguese', native: 'Português' },
];

const REGIONS = [
    { id: 'US', name: 'United States', clock24: false },
    { id: 'GB', name: 'United Kingdom', clock24: true },
    { id: 'CA', name: 'Canada', clock24: false },
    { id: 'AU', name: 'Australia', clock24: false },
    { id: 'IE', name: 'Ireland', clock24: true },
    { id: 'ES', name: 'España', clock24: true },
    { id: 'MX', name: 'México', clock24: false },
    { id: 'FR', name: 'France', clock24: true },
    { id: 'BE', name: 'Belgique / België', clock24: true },
    { id: 'DE', name: 'Deutschland', clock24: true },
    { id: 'NL', name: 'Nederland', clock24: true },
    { id: 'BR', name: 'Brasil', clock24: true },
    { id: 'PT', name: 'Portugal', clock24: true },
];

const regionById = (id) => REGIONS.find((r) => r.id === id) || REGIONS[0];

/* ---------------------------------------------------------------------
   Units & formats — every one is the player's own choice, independent of
   language and region. Defaults come from Config.DefaultUnits.
   --------------------------------------------------------------------- */

const UNIT_OPTIONS = {
    temp:     { key: 'unitTemp',     label: 'Temperature',       icon: 'fa-temperature-half', options: [['F', '°F'], ['C', '°C']] },
    distance: { key: 'unitDistance', label: 'Distance',          icon: 'fa-ruler',            options: [['mi', 'Miles'], ['km', 'Kilometres']] },
    speed:    { key: 'unitSpeed',    label: 'Speed',             icon: 'fa-gauge-high',       options: [['mph', 'mph'], ['kmh', 'km/h']] },
    weight:   { key: 'unitWeight',   label: 'Weight',            icon: 'fa-weight-scale',     options: [['lb', 'Pounds'], ['kg', 'Kilograms'], ['st', 'Stone']] },
    clock:    { key: 'clockFormat',  label: 'Time Format',       icon: 'fa-clock',            options: [['12', '12-hour'], ['24', '24-hour']] },
    date:     { key: 'dateFormat',   label: 'Date Format',       icon: 'fa-calendar-day',     options: [['MDY', 'MM/DD/YYYY'], ['DMY', 'DD/MM/YYYY'], ['YMD', 'YYYY-MM-DD']] },
    week:     { key: 'weekStart',    label: 'First Day of Week', icon: 'fa-calendar-week',    options: [['sun', 'Sunday'], ['mon', 'Monday']] },
};

const UNIT_FALLBACK = { temp: 'F', distance: 'mi', speed: 'mph', weight: 'lb', clock: '12', date: 'MDY', week: 'sun' };
const METRIC_SET = { temp: 'C', distance: 'km', speed: 'kmh', weight: 'kg' };

/** the player's choice for a unit kind (with legacy settings + server defaults) */
function unit(kind) {
    const s = Phone.settings || {};
    const def = UNIT_OPTIONS[kind];
    const v = s[def.key];
    if (v && def.options.some((o) => o[0] === v)) return v;
    // settings saved by older versions
    if (s.units === 'metric' && METRIC_SET[kind]) return METRIC_SET[kind];
    if (s.units === 'imperial' && METRIC_SET[kind]) return UNIT_FALLBACK[kind];
    if (kind === 'clock' && typeof s.clock24 === 'boolean') return s.clock24 ? '24' : '12';
    const d = Phone.profile && Phone.profile.defaultUnits;
    if (d && typeof d === 'object' && d[kind] && def.options.some((o) => o[0] === d[kind])) return d[kind];
    return UNIT_FALLBACK[kind];
}

/** settings object with every unit choice resolved (for saving) */
function unitSettings() {
    const out = {};
    Object.entries(UNIT_OPTIONS).forEach(([kind, d]) => { out[d.key] = unit(kind); });
    return out;
}

Object.defineProperty(Phone, 'locale', {
    get() {
        const s = Phone.settings || {};
        const region = regionById(s.region);
        return `${s.language || 'en'}-${region.id}-u-hc-${unit('clock') === '24' ? 'h23' : 'h12'}`;
    },
});

/** kept for older call sites: "is distance metric" */
const isMetric = () => unit('distance') === 'km';
const defaultUnits = () => 'imperial';

/** hours:minutes without the AM/PM part (status bar, lock screen) */
function clockHM(d = new Date()) {
    try {
        return new Intl.DateTimeFormat(Phone.locale, { hour: 'numeric', minute: '2-digit' })
            .formatToParts(d).filter((p) => p.type !== 'dayPeriod').map((p) => p.value).join('').trim();
    } catch (_) {
        return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' }).replace(/\s?[AP]M/, '');
    }
}

/** game data is in °F */
const tempFromF = (f) => (unit('temp') === 'C' ? Math.round(((f - 32) * 5) / 9) : Math.round(f));
const tempSym = () => (unit('temp') === 'C' ? '°C' : '°F');

/** distance in metres -> "0.4 mi" / "650 m" */
function fmtDist(m) {
    if (m == null) return '';
    if (unit('distance') === 'km') return m < 1000 ? `${Math.round(m / 10) * 10} m` : `${(m / 1000).toFixed(1)} km`;
    const mi = m / 1609.34;
    return mi < 0.1 ? `${Math.round(m * 3.281)} ft` : `${mi.toFixed(1)} mi`;
}

/** speed given in mph */
const speedNum = (mph) => Math.round(unit('speed') === 'kmh' ? mph * 1.609344 : mph);
const speedSym = () => (unit('speed') === 'kmh' ? 'km/h' : 'mph');
const fmtSpeed = (mph) => `${speedNum(mph)} ${speedSym()}`;

/** weight given in kg -> "180 lb" / "82 kg" / "12 st 13 lb" */
function fmtWeight(kg) {
    if (kg == null) return '';
    const u = unit('weight');
    if (u === 'kg') return `${Math.round(kg * 10) / 10} kg`;
    const lb = kg * 2.20462;
    if (u === 'st') {
        const st = Math.floor(lb / 14);
        return `${st} st ${Math.round(lb - st * 14)} lb`;
    }
    return `${Math.round(lb)} lb`;
}

/** numeric date in the chosen order */
function fmtDate(v) {
    const d = toDate(v);
    const dd = String(d.getDate()).padStart(2, '0'), mm = String(d.getMonth() + 1).padStart(2, '0'), yy = d.getFullYear();
    switch (unit('date')) {
        case 'DMY': return `${dd}/${mm}/${yy}`;
        case 'YMD': return `${yy}-${mm}-${dd}`;
        default: return `${mm}/${dd}/${yy}`;
    }
}

/** 0 = Sunday first, 1 = Monday first */
const weekOffset = () => (unit('week') === 'mon' ? 1 : 0);

/** single-letter weekday headers in the chosen language, starting on the chosen day */
function weekLetters() {
    const base = new Date(2023, 0, 1); // a Sunday
    return Array.from({ length: 7 }, (_, i) => {
        const d = new Date(base); d.setDate(1 + i + weekOffset());
        return d.toLocaleDateString(Phone.locale, { weekday: 'narrow' });
    });
}

/** a live preview of every unit choice */
function unitsPreviewHtml() {
    const now = new Date();
    return `
        <div><i class="fa-regular fa-clock"></i>${esc(now.toLocaleTimeString(Phone.locale, { hour: 'numeric', minute: '2-digit' }))}</div>
        <div><i class="fa-regular fa-calendar"></i>${esc(fmtDate(now))}</div>
        <div><i class="fa-solid fa-temperature-half"></i>${tempFromF(72)}${tempSym()}</div>
        <div><i class="fa-solid fa-ruler"></i>${esc(fmtDist(1609.34 * 2.5))}</div>
        <div><i class="fa-solid fa-gauge-high"></i>${esc(fmtSpeed(60))}</div>
        <div><i class="fa-solid fa-weight-scale"></i>${esc(fmtWeight(82))}</div>`;
}

/** editor used by Setup and Settings: one segmented control per unit kind */
function unitsEditorHtml() {
    return Object.entries(UNIT_OPTIONS).map(([kind, d]) => `
        <div class="unit-row">
            <div class="unit-label"><i class="fa-solid ${d.icon}"></i><span>${esc(d.label)}</span></div>
            <div class="segmented unit-seg">${d.options.map(([v, l]) => `<button data-unit-kind="${kind}" data-unit-val="${v}" class="${unit(kind) === v ? 'on' : ''}">${esc(l)}</button>`).join('')}</div>
        </div>`).join('');
}

/** wires an editor; onChange(key, value) persists the choice */
function bindUnitsEditor(root, onChange) {
    root.addEventListener('click', (e) => {
        const b = e.target.closest('[data-unit-kind]');
        if (!b) return;
        const def = UNIT_OPTIONS[b.dataset.unitKind];
        // pin every current choice first, so dropping the legacy combined
        // setting never changes the units the player didn't touch
        const all = unitSettings();
        all[def.key] = b.dataset.unitVal;
        Object.assign(Phone.settings, all);
        delete Phone.settings.units;
        delete Phone.settings.clock24;
        $$(`[data-unit-kind="${b.dataset.unitKind}"]`, root).forEach((x) => x.classList.toggle('on', x === b));
        const prev = $('.units-preview', root);
        if (prev) prev.innerHTML = unitsPreviewHtml();
        tick(true);
        onChange && onChange({ ...all, units: '' });
    });
}

/* ---------------------------------------------------------------------
   translations: English -> [es, fr, de, pt]
   --------------------------------------------------------------------- */

const T = {
    // apps
    'Phone': ['Teléfono', 'Téléphone', 'Telefon', 'Telefone'],
    'Messages': ['Mensajes', 'Messages', 'Nachrichten', 'Mensagens'],
    'Contacts': ['Contactos', 'Contacts', 'Kontakte', 'Contactos'],
    'Mail': ['Correo', 'Mail', 'Mail', 'Mail'],
    'Camera': ['Cámara', 'Appareil photo', 'Kamera', 'Câmara'],
    'Photos': ['Fotos', 'Photos', 'Fotos', 'Fotos'],
    'Notes': ['Notas', 'Notes', 'Notizen', 'Notas'],
    'Calculator': ['Calculadora', 'Calculette', 'Rechner', 'Calculadora'],
    'Clock': ['Reloj', 'Horloge', 'Uhr', 'Relógio'],
    'Weather': ['Tiempo', 'Météo', 'Wetter', 'Tempo'],
    'Maps': ['Mapas', 'Plans', 'Karten', 'Mapas'],
    'Wallet': ['Cartera', 'Cartes', 'Wallet', 'Carteira'],
    'Settings': ['Ajustes', 'Réglages', 'Einstellungen', 'Definições'],
    'Garage': ['Garaje', 'Garage', 'Garage', 'Garagem'],
    'Services': ['Servicios', 'Services', 'Dienste', 'Serviços'],
    'Calendar': ['Calendario', 'Calendrier', 'Kalender', 'Calendário'],
    'Developer': ['Desarrollador', 'Développeur', 'Entwickler', 'Programador'],
    // common
    'Cancel': ['Cancelar', 'Annuler', 'Abbrechen', 'Cancelar'],
    'Done': ['OK', 'OK', 'Fertig', 'OK'],
    'OK': ['Aceptar', 'OK', 'OK', 'OK'],
    'Save': ['Guardar', 'Enregistrer', 'Sichern', 'Guardar'],
    'Edit': ['Editar', 'Modifier', 'Bearbeiten', 'Editar'],
    'Delete': ['Eliminar', 'Supprimer', 'Löschen', 'Apagar'],
    'Deleted': ['Eliminado', 'Supprimé', 'Gelöscht', 'Apagado'],
    'Send': ['Enviar', 'Envoyer', 'Senden', 'Enviar'],
    'Sent': ['Enviado', 'Envoyé', 'Gesendet', 'Enviado'],
    'Back': ['Atrás', 'Retour', 'Zurück', 'Voltar'],
    'Close': ['Cerrar', 'Fermer', 'Schließen', 'Fechar'],
    'Search': ['Buscar', 'Rechercher', 'Suchen', 'Pesquisar'],
    'Clear': ['Borrar', 'Effacer', 'Löschen', 'Limpar'],
    'Hide': ['Ocultar', 'Masquer', 'Ausblenden', 'Ocultar'],
    'Start': ['Iniciar', 'Démarrer', 'Start', 'Iniciar'],
    'Stop': ['Detener', 'Arrêter', 'Stopp', 'Parar'],
    'All': ['Todas', 'Tous', 'Alle', 'Todas'],
    'None': ['Ninguno', 'Aucun', 'Keine', 'Nenhum'],
    'Other': ['Otros', 'Autres', 'Andere', 'Outros'],
    'Today': ['Hoy', 'Aujourd’hui', 'Heute', 'Hoje'],
    'Yesterday': ['Ayer', 'Hier', 'Gestern', 'Ontem'],
    'Name': ['Nombre', 'Nom', 'Name', 'Nome'],
    'Email': ['Correo electrónico', 'E-mail', 'E-Mail', 'E-mail'],
    'Password': ['Contraseña', 'Mot de passe', 'Passwort', 'Palavra-passe'],
    'Label': ['Etiqueta', 'Libellé', 'Etikett', 'Etiqueta'],
    'Sound': ['Sonido', 'Son', 'Ton', 'Som'],
    'Continue': ['Continuar', 'Continuer', 'Weiter', 'Continuar'],
    'Next': ['Siguiente', 'Suivant', 'Weiter', 'Seguinte'],
    'Skip': ['Omitir', 'Ignorer', 'Überspringen', 'Ignorar'],
    'Get Started': ['Empezar', 'Commencer', 'Los geht’s', 'Começar'],
    'Set Up Later': ['Configurar más tarde', 'Configurer plus tard', 'Später konfigurieren', 'Configurar mais tarde'],
    'Locating…': ['Localizando…', 'Localisation…', 'Ortung …', 'A localizar…'],
    'Delivered': ['Entregado', 'Distribué', 'Zugestellt', 'Entregue'],
    'Not Delivered': ['No entregado', 'Non distribué', 'Nicht zugestellt', 'Não entregue'],
    'Please wait': ['Espera', 'Veuillez patienter', 'Bitte warten', 'Aguarde'],
    // lock / system
    'Swipe up to open': ['Desliza hacia arriba para abrir', 'Balayez vers le haut pour ouvrir', 'Zum Öffnen nach oben streichen', 'Desliza para cima para abrir'],
    'Enter Passcode': ['Introduce el código', 'Saisissez le code', 'Code eingeben', 'Introduza o código'],
    'Emergency': ['Emergencia', 'Urgence', 'Notruf', 'Emergência'],
    'Notification Centre': ['Centro de notificaciones', 'Centre de notifications', 'Mitteilungszentrale', 'Central de notificações'],
    'No Older Notifications': ['No hay notificaciones anteriores', 'Aucune notification antérieure', 'Keine älteren Mitteilungen', 'Sem notificações antigas'],
    'Not Playing': ['No se está reproduciendo', 'Aucune lecture', 'Keine Wiedergabe', 'Nada em reprodução'],
    'Music': ['Música', 'Musique', 'Musik', 'Música'],
    'Focus': ['Concentración', 'Concentration', 'Fokus', 'Foco'],
    'Do Not Disturb': ['No molestar', 'Ne pas déranger', 'Nicht stören', 'Não incomodar'],
    'Silent': ['Silencio', 'Silencieux', 'Stumm', 'Silêncio'],
    'Ring': ['Sonido', 'Sonnerie', 'Klingeln', 'Toque'],
    'Silent Mode': ['Modo silencio', 'Mode silencieux', 'Stummmodus', 'Modo silencioso'],
    // phone
    'Favourites': ['Favoritos', 'Favoris', 'Favoriten', 'Favoritos'],
    'Recents': ['Recientes', 'Récents', 'Anrufliste', 'Recentes'],
    'Keypad': ['Teclado', 'Clavier', 'Ziffernblock', 'Teclado'],
    'Voicemail': ['Buzón de voz', 'Messagerie', 'Voicemail', 'Correio de voz'],
    'No Voicemail': ['No hay mensajes de voz', 'Aucun message vocal', 'Keine Voicemail', 'Sem correio de voz'],
    'Missed': ['Perdidas', 'Manqués', 'Verpasst', 'Perdidas'],
    'Missed Call': ['Llamada perdida', 'Appel manqué', 'Verpasster Anruf', 'Chamada não atendida'],
    'No Recents': ['No hay recientes', 'Aucun appel récent', 'Keine Anrufe', 'Sem recentes'],
    'No Favourites': ['No hay favoritos', 'Aucun favori', 'Keine Favoriten', 'Sem favoritos'],
    'Clear All Recents': ['Borrar todos los recientes', 'Effacer tous les récents', 'Alle Anrufe löschen', 'Limpar todos os recentes'],
    'Add Number': ['Añadir número', 'Ajouter le numéro', 'Nummer hinzufügen', 'Adicionar número'],
    'Accept': ['Aceptar', 'Accepter', 'Annehmen', 'Aceitar'],
    'Decline': ['Rechazar', 'Refuser', 'Ablehnen', 'Recusar'],
    'Remind Me': ['Recordar', 'Me rappeler', 'Erinnern', 'Lembrar'],
    'Message': ['Mensaje', 'Message', 'Nachricht', 'Mensagem'],
    'Call Ended': ['Llamada finalizada', 'Appel terminé', 'Anruf beendet', 'Chamada terminada'],
    'Call Failed': ['Error en la llamada', 'Échec de l’appel', 'Anruf fehlgeschlagen', 'Falha na chamada'],
    'Busy': ['Ocupado', 'Occupé', 'Besetzt', 'Ocupado'],
    'Already in a call': ['Ya estás en una llamada', 'Déjà en ligne', 'Bereits im Gespräch', 'Já está numa chamada'],
    'Turn Off Airplane Mode to Make a Call': ['Desactiva el modo avión para llamar', 'Désactivez le mode Avion pour appeler', 'Flugmodus für Anrufe deaktivieren', 'Desative o modo de voo para ligar'],
    // contacts
    'My Card': ['Mi tarjeta', 'Ma fiche', 'Meine Karte', 'O meu cartão'],
    'No Contacts': ['No hay contactos', 'Aucun contact', 'Keine Kontakte', 'Sem contactos'],
    'New Contact': ['Nuevo contacto', 'Nouveau contact', 'Neuer Kontakt', 'Novo contacto'],
    'Add Photo': ['Añadir foto', 'Ajouter une photo', 'Foto hinzufügen', 'Adicionar foto'],
    'Delete Contact': ['Eliminar contacto', 'Supprimer le contact', 'Kontakt löschen', 'Apagar contacto'],
    'Block Contact': ['Bloquear contacto', 'Bloquer le contact', 'Kontakt blockieren', 'Bloquear contacto'],
    'Block this Caller': ['Bloquear este contacto', 'Bloquer ce correspondant', 'Anrufer blockieren', 'Bloquear este contacto'],
    'Unblock this Caller': ['Desbloquear este contacto', 'Débloquer ce correspondant', 'Anrufer freigeben', 'Desbloquear este contacto'],
    'Send Message': ['Enviar mensaje', 'Envoyer un message', 'Nachricht senden', 'Enviar mensagem'],
    'Add to Favourites': ['Añadir a favoritos', 'Ajouter aux favoris', 'Zu Favoriten', 'Adicionar aos favoritos'],
    'Remove from Favourites': ['Quitar de favoritos', 'Retirer des favoris', 'Aus Favoriten entfernen', 'Remover dos favoritos'],
    'Share My Live Location': ['Compartir mi ubicación en tiempo real', 'Partager ma position en direct', 'Live-Standort teilen', 'Partilhar localização em direto'],
    'OpsDrop': ['OpsDrop', 'OpsDrop', 'OpsDrop', 'OpsDrop'],
    'No People Found': ['No se encontraron personas', 'Aucune personne', 'Keine Personen gefunden', 'Ninguém encontrado'],
    // messages
    'New Message': ['Nuevo mensaje', 'Nouveau message', 'Neue Nachricht', 'Nova mensagem'],
    'No Messages': ['No hay mensajes', 'Aucun message', 'Keine Nachrichten', 'Sem mensagens'],
    'Delete Conversation': ['Eliminar conversación', 'Supprimer la conversation', 'Konversation löschen', 'Apagar conversa'],
    'Share Live Location': ['Compartir ubicación en tiempo real', 'Partager la position en direct', 'Live-Standort teilen', 'Partilhar localização em direto'],
    'Send Current Location': ['Enviar ubicación actual', 'Envoyer la position actuelle', 'Aktuellen Standort senden', 'Enviar localização atual'],
    'Image from URL': ['Imagen desde URL', 'Image depuis une URL', 'Bild von URL', 'Imagem de URL'],
    'Shared Location': ['Ubicación compartida', 'Position partagée', 'Geteilter Standort', 'Localização partilhada'],
    'Tap to set GPS': ['Toca para fijar el GPS', 'Touchez pour le GPS', 'Tippen für GPS', 'Toque para definir GPS'],
    'Live Location': ['Ubicación en tiempo real', 'Position en direct', 'Live-Standort', 'Localização em direto'],
    'Sharing My Location': ['Compartiendo mi ubicación', 'Partage de ma position', 'Mein Standort wird geteilt', 'A partilhar a minha localização'],
    'Stop Sharing': ['Dejar de compartir', 'Arrêter le partage', 'Teilen beenden', 'Parar partilha'],
    'Stop Sharing Location': ['Dejar de compartir ubicación', 'Arrêter de partager la position', 'Standortfreigabe beenden', 'Parar de partilhar localização'],
    'Live location ended': ['La ubicación en tiempo real terminó', 'Position en direct terminée', 'Live-Standort beendet', 'Localização em direto terminada'],
    'Directions': ['Indicaciones', 'Itinéraire', 'Route', 'Direções'],
    'Follow': ['Seguir', 'Suivre', 'Folgen', 'Seguir'],
    'Following': ['Siguiendo', 'Suivi', 'Folge ich', 'A seguir'],
    'Share for 15 Minutes': ['Compartir durante 15 minutos', 'Partager 15 minutes', '15 Minuten teilen', 'Partilhar 15 minutos'],
    'Share for One Hour': ['Compartir durante una hora', 'Partager une heure', 'Eine Stunde teilen', 'Partilhar uma hora'],
    'Share Until I Stop': ['Compartir hasta que pare', 'Partager jusqu’à l’arrêt', 'Teilen bis ich stoppe', 'Partilhar até parar'],
    // mail
    'Mailboxes': ['Buzones', 'Boîtes', 'Postfächer', 'Caixas'],
    'Inbox': ['Recibidos', 'Réception', 'Eingang', 'Entrada'],
    'No Mail': ['No hay correo', 'Aucun e-mail', 'Keine E-Mails', 'Sem e-mail'],
    'Updated Just Now': ['Actualizado ahora', 'Mis à jour à l’instant', 'Gerade aktualisiert', 'Atualizado agora'],
    'Cannot Send Mail': ['No se puede enviar', 'Envoi impossible', 'E-Mail kann nicht gesendet werden', 'Não é possível enviar'],
    // notes / photos
    'No Notes': ['No hay notas', 'Aucune note', 'Keine Notizen', 'Sem notas'],
    'Start typing…': ['Empieza a escribir…', 'Commencez à écrire…', 'Schreib los …', 'Comece a escrever…'],
    'Library': ['Biblioteca', 'Photothèque', 'Mediathek', 'Biblioteca'],
    'All Photos': ['Todas las fotos', 'Toutes les photos', 'Alle Fotos', 'Todas as fotos'],
    'No Photos': ['No hay fotos', 'Aucune photo', 'Keine Fotos', 'Sem fotos'],
    'Delete Photo': ['Eliminar foto', 'Supprimer la photo', 'Foto löschen', 'Apagar foto'],
    'Wallpaper set': ['Fondo establecido', 'Fond d’écran défini', 'Hintergrund gesetzt', 'Fundo definido'],
    // clock
    'World Clock': ['Reloj mundial', 'Horloge', 'Weltuhr', 'Relógio mundial'],
    'Alarms': ['Alarmas', 'Alarmes', 'Wecker', 'Alarmes'],
    'Alarm': ['Alarma', 'Alarme', 'Wecker', 'Alarme'],
    'Stopwatch': ['Cronómetro', 'Chronomètre', 'Stoppuhr', 'Cronómetro'],
    'Timers': ['Temporizadores', 'Minuteurs', 'Timer', 'Temporizadores'],
    'Timer': ['Temporizador', 'Minuteur', 'Timer', 'Temporizador'],
    'Lap': ['Vuelta', 'Tour', 'Runde', 'Volta'],
    'No Alarm': ['Sin alarma', 'Aucune alarme', 'Kein Wecker', 'Sem alarme'],
    'No alarms': ['Sin alarmas', 'Aucune alarme', 'Keine Wecker', 'Sem alarmes'],
    'Delete Alarm': ['Eliminar alarma', 'Supprimer l’alarme', 'Wecker löschen', 'Apagar alarme'],
    'Choose a City': ['Elige una ciudad', 'Choisissez une ville', 'Stadt wählen', 'Escolha uma cidade'],
    'When Timer Ends': ['Al finalizar', 'Fin du minuteur', 'Timer-Ende', 'Quando terminar'],
    // weather
    'My Location': ['Mi ubicación', 'Ma position', 'Mein Standort', 'A minha localização'],
    'UV INDEX': ['ÍNDICE UV', 'INDICE UV', 'UV-INDEX', 'ÍNDICE UV'],
    'HUMIDITY': ['HUMEDAD', 'HUMIDITÉ', 'LUFTFEUCHTIGKEIT', 'HUMIDADE'],
    'WIND': ['VIENTO', 'VENT', 'WIND', 'VENTO'],
    'VISIBILITY': ['VISIBILIDAD', 'VISIBILITÉ', 'SICHT', 'VISIBILIDADE'],
    '10-DAY FORECAST': ['PREVISIÓN A 10 DÍAS', 'PRÉVISIONS SUR 10 JOURS', '10-TAGE-VORHERSAGE', 'PREVISÃO A 10 DIAS'],
    // maps
    'Search Maps': ['Buscar en Mapas', 'Rechercher dans Plans', 'In Karten suchen', 'Pesquisar Mapas'],
    'Current Location': ['Ubicación actual', 'Position actuelle', 'Aktueller Standort', 'Localização atual'],
    'Places': ['Lugares', 'Lieux', 'Orte', 'Locais'],
    'People': ['Personas', 'Personnes', 'Personen', 'Pessoas'],
    'No results': ['Sin resultados', 'Aucun résultat', 'Keine Ergebnisse', 'Sem resultados'],
    'GPS set': ['GPS fijado', 'GPS défini', 'GPS gesetzt', 'GPS definido'],
    // wallet
    'Balance': ['Saldo', 'Solde', 'Kontostand', 'Saldo'],
    'Bank': ['Banco', 'Banque', 'Bank', 'Banco'],
    'Cash': ['Efectivo', 'Espèces', 'Bargeld', 'Dinheiro'],
    'Request': ['Solicitar', 'Demander', 'Anfordern', 'Pedir'],
    'Bills Due': ['Facturas pendientes', 'Factures à payer', 'Offene Rechnungen', 'Faturas pendentes'],
    'Latest Transactions': ['Últimas transacciones', 'Dernières transactions', 'Letzte Umsätze', 'Últimas transações'],
    'No transactions yet': ['Aún no hay transacciones', 'Aucune transaction', 'Noch keine Umsätze', 'Ainda sem transações'],
    'Pay': ['Pagar', 'Payer', 'Bezahlen', 'Pagar'],
    'Pay Bill': ['Pagar factura', 'Payer la facture', 'Rechnung bezahlen', 'Pagar fatura'],
    'Bill paid': ['Factura pagada', 'Facture payée', 'Rechnung bezahlt', 'Fatura paga'],
    'Payment Failed': ['Pago fallido', 'Échec du paiement', 'Zahlung fehlgeschlagen', 'Falha no pagamento'],
    'Send Money': ['Enviar dinero', 'Envoyer de l’argent', 'Geld senden', 'Enviar dinheiro'],
    'Request sent': ['Solicitud enviada', 'Demande envoyée', 'Anfrage gesendet', 'Pedido enviado'],
    'To': ['Para', 'À', 'An', 'Para'],
    'Note': ['Nota', 'Note', 'Notiz', 'Nota'],
    // garage / services
    'My Vehicles': ['Mis vehículos', 'Mes véhicules', 'Meine Fahrzeuge', 'Os meus veículos'],
    'In Garage': ['En el garaje', 'Au garage', 'In der Garage', 'Na garagem'],
    'Impounded': ['Incautado', 'En fourrière', 'Abgeschleppt', 'Apreendido'],
    'Out': ['Fuera', 'Sorti', 'Unterwegs', 'Fora'],
    'Dispatch': ['Despacho', 'Répartition', 'Einsätze', 'Despacho'],
    'No active requests': ['No hay solicitudes activas', 'Aucune demande active', 'Keine aktiven Einsätze', 'Sem pedidos ativos'],
    'Respond': ['Responder', 'Intervenir', 'Übernehmen', 'Responder'],
    'Your GPS location will be shared': ['Se compartirá tu ubicación GPS', 'Votre position GPS sera partagée', 'Dein GPS-Standort wird geteilt', 'A sua localização GPS será partilhada'],
    'Describe what\'s happening…': ['Describe lo que pasa…', 'Décrivez la situation…', 'Beschreibe, was passiert …', 'Descreva o que se passa…'],
    // calendar
    'No Events': ['No hay eventos', 'Aucun événement', 'Keine Ereignisse', 'Sem eventos'],
    'Enjoy your day in Los Santos': ['Disfruta tu día en Los Santos', 'Bonne journée à Los Santos', 'Genieß deinen Tag in Los Santos', 'Aproveite o dia em Los Santos'],
    // settings
    'Airplane Mode': ['Modo avión', 'Mode Avion', 'Flugmodus', 'Modo de voo'],
    'Bluetooth': ['Bluetooth', 'Bluetooth', 'Bluetooth', 'Bluetooth'],
    'Cellular': ['Datos móviles', 'Données cellulaires', 'Mobilfunk', 'Rede móvel'],
    'Notifications': ['Notificaciones', 'Notifications', 'Mitteilungen', 'Notificações'],
    'Sounds & Haptics': ['Sonidos y vibraciones', 'Sons et vibrations', 'Töne & Haptik', 'Sons e vibração'],
    'General': ['General', 'Général', 'Allgemein', 'Geral'],
    'Accessibility': ['Accesibilidad', 'Accessibilité', 'Bedienungshilfen', 'Acessibilidade'],
    'Display & Brightness': ['Pantalla y brillo', 'Luminosité et affichage', 'Anzeige & Helligkeit', 'Ecrã e brilho'],
    'Wallpaper': ['Fondo de pantalla', 'Fond d’écran', 'Hintergrundbild', 'Fundo'],
    'Face Unlock & Passcode': ['Desbloqueo facial y código', 'Déverrouillage facial et code', 'Gesichtsentsperrung & Code', 'Desbloqueio facial e código'],
    'Battery': ['Batería', 'Batterie', 'Batterie', 'Bateria'],
    'Performance': ['Rendimiento', 'Performances', 'Leistung', 'Desempenho'],
    'Language & Region': ['Idioma y región', 'Langue et région', 'Sprache & Region', 'Idioma e região'],
    'Language': ['Idioma', 'Langue', 'Sprache', 'Idioma'],
    'Region': ['Región', 'Région', 'Region', 'Região'],
    '24-Hour Time': ['Formato de 24 horas', 'Format 24 heures', '24-Stunden-Format', 'Formato de 24 horas'],
    'Temperature': ['Temperatura', 'Température', 'Temperatur', 'Temperatura'],
    'Measurement System': ['Sistema de medida', 'Système de mesure', 'Maßsystem', 'Sistema de medida'],
    'Metric': ['Métrico', 'Métrique', 'Metrisch', 'Métrico'],
    'Imperial': ['Imperial', 'Impérial', 'Imperial', 'Imperial'],
    'Units': ['Unidades', 'Unités', 'Einheiten', 'Unidades'],
    'Units & Formats': ['Unidades y formatos', 'Unités et formats', 'Einheiten & Formate', 'Unidades e formatos'],
    'Distance': ['Distancia', 'Distance', 'Entfernung', 'Distância'],
    'Speed': ['Velocidad', 'Vitesse', 'Geschwindigkeit', 'Velocidade'],
    'Weight': ['Peso', 'Poids', 'Gewicht', 'Peso'],
    'Time Format': ['Formato de hora', 'Format de l’heure', 'Uhrzeitformat', 'Formato da hora'],
    'Date Format': ['Formato de fecha', 'Format de date', 'Datumsformat', 'Formato da data'],
    'First Day of Week': ['Primer día de la semana', 'Premier jour de la semaine', 'Erster Wochentag', 'Primeiro dia da semana'],
    'Miles': ['Millas', 'Miles', 'Meilen', 'Milhas'],
    'Kilometres': ['Kilómetros', 'Kilomètres', 'Kilometer', 'Quilómetros'],
    'Pounds': ['Libras', 'Livres', 'Pfund', 'Libras'],
    'Kilograms': ['Kilogramos', 'Kilogrammes', 'Kilogramm', 'Quilogramas'],
    'Stone': ['Stone', 'Stone', 'Stone', 'Stone'],
    '12-hour': ['12 horas', '12 heures', '12 Stunden', '12 horas'],
    '24-hour': ['24 horas', '24 heures', '24 Stunden', '24 horas'],
    'Sunday': ['Domingo', 'Dimanche', 'Sonntag', 'Domingo'],
    'Monday': ['Lunes', 'Lundi', 'Montag', 'Segunda-feira'],
    'Pick each one — they don’t depend on your language.': ['Elige cada una: no dependen de tu idioma.', 'Choisissez chacune : elles ne dépendent pas de votre langue.', 'Wähle jede einzeln – unabhängig von deiner Sprache.', 'Escolha cada uma: não dependem do idioma.'],
    'Region decides number formatting only. Every unit is set in Units & Formats.': ['La región solo afecta al formato de números. Las unidades se eligen en Unidades y formatos.', 'La région ne règle que le format des nombres. Les unités se choisissent dans Unités et formats.', 'Die Region bestimmt nur das Zahlenformat. Einheiten wählst du unter Einheiten & Formate.', 'A região só define o formato dos números. As unidades escolhem-se em Unidades e formatos.'],
    'Miles · °F': ['Millas · °F', 'Miles · °F', 'Meilen · °F', 'Milhas · °F'],
    'Kilometres · °C': ['Kilómetros · °C', 'Kilomètres · °C', 'Kilometer · °C', 'Quilómetros · °C'],
    'This sets your date and time format.': ['Define el formato de fecha y hora.', 'Définit le format de la date et de l’heure.', 'Legt das Datums- und Uhrzeitformat fest.', 'Define o formato de data e hora.'],
    'About': ['Información', 'Informations', 'Info', 'Acerca de'],
    'Software Update': ['Actualización de software', 'Mise à jour logicielle', 'Softwareupdate', 'Atualização de software'],
    'Storage': ['Almacenamiento', 'Stockage', 'Speicher', 'Armazenamento'],
    'Date & Time': ['Fecha y hora', 'Date et heure', 'Datum & Uhrzeit', 'Data e hora'],
    'Keyboard': ['Teclado', 'Clavier', 'Tastatur', 'Teclado'],
    'Automatic': ['Automático', 'Automatique', 'Automatisch', 'Automático'],
    'Transfer or Reset Phone': ['Transferir o restablecer', 'Transférer ou réinitialiser', 'Übertragen/Zurücksetzen', 'Transferir ou repor'],
    'Reset All Settings': ['Restablecer ajustes', 'Réinitialiser tous les réglages', 'Alle Einstellungen zurücksetzen', 'Repor todas as definições'],
    'Settings reset': ['Ajustes restablecidos', 'Réglages réinitialisés', 'Einstellungen zurückgesetzt', 'Definições repostas'],
    'Appearance': ['Apariencia', 'Apparence', 'Erscheinungsbild', 'Aspeto'],
    'Light': ['Claro', 'Clair', 'Hell', 'Claro'],
    'Dark': ['Oscuro', 'Sombre', 'Dunkel', 'Escuro'],
    'Brightness': ['Brillo', 'Luminosité', 'Helligkeit', 'Brilho'],
    'Auto-Lock': ['Bloqueo automático', 'Verrouillage auto', 'Automatische Sperre', 'Bloqueio automático'],
    'Immediately': ['Inmediatamente', 'Immédiatement', 'Sofort', 'Imediatamente'],
    'After 30 Seconds': ['A los 30 segundos', 'Après 30 secondes', 'Nach 30 Sekunden', 'Após 30 segundos'],
    'After 1 Minute': ['Al minuto', 'Après 1 minute', 'Nach 1 Minute', 'Após 1 minuto'],
    'After 5 Minutes': ['A los 5 minutos', 'Après 5 minutes', 'Nach 5 Minuten', 'Após 5 minutos'],
    'Never': ['Nunca', 'Jamais', 'Nie', 'Nunca'],
    'Display Zoom': ['Zoom de pantalla', 'Zoom de l’écran', 'Anzeigezoom', 'Zoom do ecrã'],
    'Smaller': ['Más pequeño', 'Plus petit', 'Kleiner', 'Mais pequeno'],
    'Default': ['Por omisión', 'Par défaut', 'Standard', 'Padrão'],
    'Larger Text': ['Texto más grande', 'Texte plus grand', 'Größerer Text', 'Texto maior'],
    'Collections': ['Colecciones', 'Collections', 'Sammlungen', 'Coleções'],
    'Choose from Photos': ['Elegir de Fotos', 'Choisir dans Photos', 'Aus Fotos wählen', 'Escolher das Fotos'],
    'Image URL…': ['URL de imagen…', 'URL de l’image…', 'Bild-URL …', 'URL da imagem…'],
    'Turn Passcode On': ['Activar código', 'Activer le code', 'Code aktivieren', 'Ativar código'],
    'Turn Passcode Off': ['Desactivar código', 'Désactiver le code', 'Code deaktivieren', 'Desativar código'],
    'Change Passcode': ['Cambiar código', 'Modifier le code', 'Code ändern', 'Alterar código'],
    'Phone Unlock': ['Desbloqueo del teléfono', 'Déverrouillage', 'Telefon entsperren', 'Desbloqueio do telefone'],
    'Use Face Unlock For': ['Usar desbloqueo facial para', 'Utiliser le déverrouillage facial pour', 'Gesichtsentsperrung verwenden für', 'Usar desbloqueio facial para'],
    'Passcode set': ['Código establecido', 'Code défini', 'Code festgelegt', 'Código definido'],
    'Incorrect Passcode': ['Código incorrecto', 'Code incorrect', 'Falscher Code', 'Código incorreto'],
    'Show Previews': ['Mostrar previsualizaciones', 'Afficher les aperçus', 'Vorschauen zeigen', 'Mostrar pré-visualizações'],
    'Always': ['Siempre', 'Toujours', 'Immer', 'Sempre'],
    'Notification Style': ['Estilo de notificación', 'Style des notifications', 'Mitteilungsstil', 'Estilo de notificação'],
    'Ringtone and Alert Volume': ['Volumen de tono y avisos', 'Volume sonnerie et alertes', 'Klingel- und Hinweistöne', 'Volume do toque e alertas'],
    'Sounds and Haptic Patterns': ['Sonidos y patrones de vibración', 'Sons et motifs de vibration', 'Töne und Vibrationsmuster', 'Sons e padrões de vibração'],
    'Battery Percentage': ['Porcentaje de batería', 'Pourcentage de la batterie', 'Batterieladung in Prozent', 'Percentagem da bateria'],
    'Battery Health': ['Salud de la batería', 'État de la batterie', 'Batteriezustand', 'Estado da bateria'],
    'Vision': ['Visión', 'Vision', 'Sehen', 'Visão'],
    'Motion': ['Movimiento', 'Mouvement', 'Bewegung', 'Movimento'],
    'Reduce Transparency': ['Reducir transparencia', 'Réduire la transparence', 'Transparenz reduzieren', 'Reduzir transparência'],
    'Reduce Motion': ['Reducir movimiento', 'Réduire les animations', 'Bewegung reduzieren', 'Reduzir movimento'],
    'Model Name': ['Nombre del modelo', 'Nom du modèle', 'Modellname', 'Nome do modelo'],
    'Serial Number': ['Número de serie', 'Numéro de série', 'Seriennummer', 'Número de série'],
    'Phone Number': ['Número de teléfono', 'Numéro de téléphone', 'Telefonnummer', 'Número de telefone'],
    'Network': ['Red', 'Réseau', 'Netz', 'Rede'],
    'Capacity': ['Capacidad', 'Capacité', 'Kapazität', 'Capacidade'],
    'Available': ['Disponible', 'Disponible', 'Verfügbar', 'Disponível'],
    'Version': ['Versión', 'Version', 'Version', 'Versão'],
    // performance presets
    'Ultra': ['Ultra', 'Ultra', 'Ultra', 'Ultra'],
    'Balanced': ['Equilibrado', 'Équilibré', 'Ausgewogen', 'Equilibrado'],
    'Run Test Again': ['Repetir la prueba', 'Relancer le test', 'Test wiederholen', 'Repetir teste'],
    'Recommended': ['Recomendado', 'Recommandé', 'Empfohlen', 'Recomendado'],
    // setup
    'Set Up Your Phone': ['Configura tu teléfono', 'Configurez votre téléphone', 'Telefon einrichten', 'Configure o telefone'],
    'Choose Your Region': ['Elige tu región', 'Choisissez votre région', 'Region wählen', 'Escolha a sua região'],
    'What’s your name?': ['¿Cómo te llamas?', 'Comment vous appelez-vous ?', 'Wie heißt du?', 'Como se chama?'],
    'Choose Your Number': ['Elige tu número', 'Choisissez votre numéro', 'Nummer wählen', 'Escolha o seu número'],
    'Create Your OPS ID': ['Crea tu OPS ID', 'Créez votre OPS ID', 'OPS ID erstellen', 'Crie o seu OPS ID'],
    'Face Unlock & Passcode Setup': ['Desbloqueo facial y código', 'Déverrouillage facial et code', 'Gesichtsentsperrung & Code', 'Desbloqueio facial e código'],
    'Choose a Look': ['Elige un aspecto', 'Choisissez un style', 'Look wählen', 'Escolha um aspeto'],
    'Optimising for Your PC': ['Optimizando para tu PC', 'Optimisation pour votre PC', 'Optimierung für deinen PC', 'A otimizar para o seu PC'],
    'Welcome to OPS OS': ['Bienvenido a OPS OS', 'Bienvenue dans OPS OS', 'Willkommen bei OPS OS', 'Bem-vindo ao OPS OS'],
    'Create Passcode': ['Crear código', 'Créer un code', 'Code erstellen', 'Criar código'],
    'Choose your language': ['Elige tu idioma', 'Choisissez votre langue', 'Wähle deine Sprache', 'Escolha o seu idioma'],
    'Tap to set up': ['Toca para configurar', 'Touchez pour configurer', 'Zum Einrichten tippen', 'Toque para configurar'],
    'This sets your date, time and units.': ['Define la fecha, la hora y las unidades.', 'Définit la date, l’heure et les unités.', 'Legt Datum, Uhrzeit und Einheiten fest.', 'Define a data, a hora e as unidades.'],
    'This is shown on your contact card and to people you message.': ['Aparece en tu tarjeta y a quien escribas.', 'Affiché sur votre fiche et à vos contacts.', 'Wird auf deiner Karte und beim Schreiben angezeigt.', 'Aparece no seu cartão e a quem escrever.'],
    'Keep the number you were given or pick your own.': ['Conserva el número asignado o elige el tuyo.', 'Gardez le numéro attribué ou choisissez le vôtre.', 'Behalte deine Nummer oder wähle eine eigene.', 'Mantenha o número atribuído ou escolha o seu.'],
    'Your email address for Mail. You can sign in to other services with it.': ['Tu correo para Mail. También sirve para otros servicios.', 'Votre adresse pour Mail, utilisable pour d’autres services.', 'Deine Adresse für Mail und andere Dienste.', 'O seu e-mail para o Mail e outros serviços.'],
    'A passcode protects your phone. Face Unlock opens it when you raise it.': ['El código protege tu teléfono. El desbloqueo facial lo abre al levantarlo.', 'Le code protège votre téléphone. Le déverrouillage facial l’ouvre quand vous le levez.', 'Ein Code schützt dein Telefon. Gesichtsentsperrung öffnet es beim Anheben.', 'O código protege o telefone. O desbloqueio facial abre-o ao levantá-lo.'],
    'You can change this any time in Settings.': ['Puedes cambiarlo en Ajustes cuando quieras.', 'Modifiable à tout moment dans Réglages.', 'Jederzeit in den Einstellungen änderbar.', 'Pode alterar nas Definições a qualquer momento.'],
    'Testing how your PC runs the phone so it stays smooth.': ['Probando cómo funciona el teléfono en tu PC para que vaya fluido.', 'Test de votre PC pour que le téléphone reste fluide.', 'Wir testen deinen PC, damit alles flüssig läuft.', 'A testar o seu PC para o telefone ficar fluido.'],
    'Testing…': ['Probando…', 'Test…', 'Test …', 'A testar…'],
    'Live blur and every animation. For strong PCs.': ['Desenfoque en vivo y todas las animaciones. Para PC potentes.', 'Flou en direct et toutes les animations. Pour PC puissants.', 'Live-Unschärfe und alle Animationen. Für starke PCs.', 'Desfoque em tempo real e todas as animações. Para PCs potentes.'],
    'Solid backgrounds instead of live blur, full animations.': ['Fondos sólidos en lugar de desenfoque, animaciones completas.', 'Fonds unis au lieu du flou, animations complètes.', 'Feste Hintergründe statt Unschärfe, alle Animationen.', 'Fundos sólidos em vez de desfoque, animações completas.'],
    'Solid backgrounds and quick fades. For low-end PCs.': ['Fondos sólidos y fundidos rápidos. Para PC modestos.', 'Fonds unis et fondus rapides. Pour PC modestes.', 'Feste Hintergründe, schnelle Übergänge. Für schwächere PCs.', 'Fundos sólidos e transições rápidas. Para PCs modestos.'],
    'fps': ['fps', 'ips', 'fps', 'fps'],
    'ms load': ['ms carga', 'ms chargement', 'ms Laden', 'ms carga'],
    'ms worst': ['ms peor', 'ms pire', 'ms max.', 'ms pior'],
    'Face Unlock': ['Desbloqueo facial', 'Déverrouillage facial', 'Gesichtsentsperrung', 'Desbloqueio facial'],
    'Available ✓': ['Disponible ✓', 'Disponible ✓', 'Verfügbar ✓', 'Disponível ✓'],
    'Open': ['Abrir', 'Ouvrir', 'Öffnen', 'Abrir'],
    'Get': ['Obtener', 'Obtenir', 'Laden', 'Obter'],
    'installed': ['instalada', 'installée', 'installiert', 'instalada'],
    'Category': ['Categoría', 'Catégorie', 'Kategorie', 'Categoria'],
    'Requires': ['Requiere', 'Requiert', 'Erfordert', 'Requer'],
    'Built into OPS OS': ['Incluida en OPS OS', 'Intégrée à OPS OS', 'In OPS OS integriert', 'Incluída no OPS OS'],
    'Remove App': ['Eliminar app', 'Supprimer l’app', 'App entfernen', 'Remover app'],
    'Remove': ['Eliminar', 'Supprimer', 'Entfernen', 'Remover'],
    'You can reinstall it any time from the OPS OS Store.': ['Puedes reinstalarla cuando quieras desde OPS OS Store.', 'Vous pouvez la réinstaller depuis l’OPS OS Store.', 'Du kannst sie jederzeit im OPS OS Store neu installieren.', 'Pode reinstalá-la a qualquer momento na OPS OS Store.'],
    'Essentials': ['Imprescindibles', 'Essentiels', 'Grundausstattung', 'Essenciais'],
    'of': ['de', 'sur', 'von', 'de'],
    'apps installed': ['apps instaladas', 'apps installées', 'Apps installiert', 'apps instaladas'],
    'Apps, categories and more': ['Apps, categorías y más', 'Apps, catégories et plus', 'Apps, Kategorien und mehr', 'Apps, categorias e mais'],
    'Discover': ['Descubrir', 'Découvrir', 'Entdecken', 'Descobrir'],
    'Apps': ['Apps', 'Apps', 'Apps', 'Apps'],
    'No Results': ['Sin resultados', 'Aucun résultat', 'Keine Ergebnisse', 'Sem resultados'],
    'Home': ['Inicio', 'Accueil', 'Start', 'Início'],
    'Your Library': ['Tu biblioteca', 'Bibliothèque', 'Bibliothek', 'A sua biblioteca'],
    'Good morning': ['Buenos días', 'Bonjour', 'Guten Morgen', 'Bom dia'],
    'Good afternoon': ['Buenas tardes', 'Bon après-midi', 'Guten Tag', 'Boa tarde'],
    'Good evening': ['Buenas noches', 'Bonsoir', 'Guten Abend', 'Boa noite'],
    'Liked Songs': ['Canciones que te gustan', 'Titres likés', 'Lieblingssongs', 'Músicas curtidas'],
    'Recently Added': ['Añadidas recientemente', 'Ajouts récents', 'Zuletzt hinzugefügt', 'Adicionadas recentemente'],
    'Radio Stations': ['Emisoras de radio', 'Stations de radio', 'Radiosender', 'Estações de rádio'],
    'Build your library': ['Crea tu biblioteca', 'Créez votre bibliothèque', 'Baue deine Bibliothek auf', 'Crie a sua biblioteca'],
    'Add a Song': ['Añadir canción', 'Ajouter un titre', 'Song hinzufügen', 'Adicionar música'],
    'Add to Library': ['Añadir a la biblioteca', 'Ajouter à la bibliothèque', 'Zur Bibliothek', 'Adicionar à biblioteca'],
    'Added to Library': ['Añadida a la biblioteca', 'Ajouté à la bibliothèque', 'Zur Bibliothek hinzugefügt', 'Adicionada à biblioteca'],
    'Add': ['Añadir', 'Ajouter', 'Hinzufügen', 'Adicionar'],
    'Link': ['Enlace', 'Lien', 'Link', 'Ligação'],
    'Title': ['Título', 'Titre', 'Titel', 'Título'],
    'Artist': ['Artista', 'Artiste', 'Künstler', 'Artista'],
    'Cover': ['Portada', 'Pochette', 'Cover', 'Capa'],
    'Playlist': ['Lista', 'Playlist', 'Playlist', 'Playlist'],
    'Optional': ['Opcional', 'Facultatif', 'Optional', 'Opcional'],
    'Liked': ['Me gusta', 'Likés', 'Gefällt mir', 'Curtidas'],
    'Play': ['Reproducir', 'Lecture', 'Abspielen', 'Reproduzir'],
    'Shuffle': ['Aleatorio', 'Aléatoire', 'Zufall', 'Aleatório'],
    'Share': ['Compartir', 'Partager', 'Teilen', 'Partilhar'],
    'Live Radio': ['Radio en directo', 'Radio en direct', 'Live-Radio', 'Rádio em direto'],
    'Live radio stream': ['Emisión de radio en directo', 'Flux radio en direct', 'Live-Radiostream', 'Transmissão de rádio'],
    'Nothing here yet': ['Aún no hay nada', 'Rien pour l’instant', 'Noch nichts hier', 'Ainda não há nada'],
    'Remove from Library': ['Quitar de la biblioteca', 'Retirer de la bibliothèque', 'Aus Bibliothek entfernen', 'Remover da biblioteca'],
    'Add to Liked Songs': ['Añadir a Me gusta', 'Ajouter aux titres likés', 'Zu Lieblingssongs', 'Adicionar às curtidas'],
    'Remove from Liked Songs': ['Quitar de Me gusta', 'Retirer des titres likés', 'Aus Lieblingssongs entfernen', 'Remover das curtidas'],
    'Add to Playlist…': ['Añadir a una lista…', 'Ajouter à une playlist…', 'Zu Playlist hinzufügen …', 'Adicionar à playlist…'],
    'What do you want to listen to?': ['¿Qué quieres escuchar?', 'Que voulez-vous écouter ?', 'Was möchtest du hören?', 'O que quer ouvir?'],
    'Add from a link': ['Añadir desde un enlace', 'Ajouter depuis un lien', 'Über Link hinzufügen', 'Adicionar de uma ligação'],
    'Add this link': ['Añadir este enlace', 'Ajouter ce lien', 'Diesen Link hinzufügen', 'Adicionar esta ligação'],
    "Couldn't play this song": ['No se pudo reproducir', 'Lecture impossible', 'Song kann nicht abgespielt werden', 'Não foi possível reproduzir'],
    'Sharing': ['Compartiendo', 'Partage', 'Wird geteilt', 'A partilhar'],
    'Connect': ['Conectar', 'Connecter', 'Verbinden', 'Ligar'],
    'Connected': ['Conectado', 'Connecté', 'Verbunden', 'Ligado'],
    'Disconnect': ['Desconectar', 'Déconnecter', 'Trennen', 'Desligar'],
    'You can connect again any time.': ['Puedes volver a conectar cuando quieras.', 'Vous pourrez vous reconnecter à tout moment.', 'Du kannst dich jederzeit wieder verbinden.', 'Pode voltar a ligar a qualquer momento.'],
    'Finish signing in in your browser': ['Termina de iniciar sesión en el navegador', 'Terminez la connexion dans votre navigateur', 'Melde dich im Browser fertig an', 'Termine o início de sessão no navegador'],
    'Your browser opened the official sign-in page. Log in, tap Agree, then come back to the game.': ['Se abrió la página oficial en tu navegador. Inicia sesión, acepta y vuelve al juego.', 'Votre navigateur a ouvert la page officielle. Connectez-vous, acceptez, puis revenez au jeu.', 'Dein Browser hat die offizielle Anmeldeseite geöffnet. Melde dich an, stimme zu und komm zurück ins Spiel.', 'O navegador abriu a página oficial. Inicie sessão, aceite e volte ao jogo.'],
    'Open the page again': ['Abrir la página otra vez', 'Rouvrir la page', 'Seite erneut öffnen', 'Abrir a página novamente'],
    "Can't connect right now": ['No se puede conectar ahora', 'Connexion impossible', 'Verbindung gerade nicht möglich', 'Não é possível ligar agora'],
    'Your Spotify': ['Tu Spotify', 'Votre Spotify', 'Dein Spotify', 'O seu Spotify'],
    'Recently Played': ['Escuchado recientemente', 'Écoutés récemment', 'Zuletzt gehört', 'Ouvidas recentemente'],
    'Play on': ['Reproducir en', 'Lire sur', 'Abspielen auf', 'Reproduzir em'],
    'Open Spotify first': ['Abre Spotify primero', 'Ouvrez d’abord Spotify', 'Öffne zuerst Spotify', 'Abra primeiro o Spotify'],
    'Spotify Premium needed': ['Se necesita Spotify Premium', 'Spotify Premium requis', 'Spotify Premium erforderlich', 'É necessário Spotify Premium'],
    'Opens in TIDAL': ['Se abre en TIDAL', 'S’ouvre dans TIDAL', 'Öffnet in TIDAL', 'Abre no TIDAL'],
    'Saved': ['Guardado', 'Enregistré', 'Gespeichert', 'Guardado'],
    'OPS ID': ['OPS ID', 'OPS ID', 'OPS ID', 'OPS ID'],
    'Use the format': ['Usa el formato', 'Utilisez le format', 'Format:', 'Use o formato'],
    'That number is taken': ['Ese número está ocupado', 'Ce numéro est déjà pris', 'Diese Nummer ist vergeben', 'Esse número já está ocupado'],
    'That address is taken': ['Esa dirección está ocupada', 'Cette adresse est déjà prise', 'Diese Adresse ist vergeben', 'Esse endereço já está ocupado'],
    '3–30 letters, numbers, dots, dashes or underscores': ['3–30 letras, números, puntos, guiones o guiones bajos', '3 à 30 lettres, chiffres, points, tirets ou traits bas', '3–30 Buchstaben, Zahlen, Punkte, Binde- oder Unterstriche', '3–30 letras, números, pontos, hífenes ou sublinhados'],
    'The server is running an old version of the phone. An admin needs to run “refresh” and then “restart opslabs-phone” in the server console.': ['El servidor usa una versión antigua del teléfono. Un admin debe ejecutar «refresh» y luego «restart opslabs-phone».', 'Le serveur utilise une ancienne version du téléphone. Un admin doit exécuter « refresh » puis « restart opslabs-phone ».', 'Der Server nutzt eine alte Telefon-Version. Ein Admin muss „refresh“ und dann „restart opslabs-phone“ ausführen.', 'O servidor usa uma versão antiga do telefone. Um admin tem de executar “refresh” e depois “restart opslabs-phone”.'],
    'Setting Up…': ['Configurando…', 'Configuration…', 'Wird eingerichtet …', 'A configurar…'],
    'Try Again': ['Reintentar', 'Réessayer', 'Erneut versuchen', 'Tentar novamente'],
    "Couldn't reach the server. Check your connection and tap Try Again.": ['No se pudo conectar con el servidor. Toca Reintentar.', 'Serveur injoignable. Touchez Réessayer.', 'Server nicht erreichbar. Tippe auf Erneut versuchen.', 'Não foi possível contactar o servidor. Toque em Tentar novamente.'],
    'Checking…': ['Comprobando…', 'Vérification…', 'Wird geprüft …', 'A verificar…'],
    'Could not check, try again': ['No se pudo comprobar, inténtalo de nuevo', 'Vérification impossible, réessayez', 'Prüfung fehlgeschlagen, erneut versuchen', 'Não foi possível verificar, tente novamente'],
};

// weather conditions are translated separately ("Clear" the sky ≠ "Clear" the button)
const WEATHER_T = {
    'Clear': ['Despejado', 'Dégagé', 'Klar', 'Limpo'],
    'Sunny': ['Soleado', 'Ensoleillé', 'Sonnig', 'Sol'],
    'Partly Cloudy': ['Parcialmente nublado', 'Partiellement nuageux', 'Teilweise bewölkt', 'Parcialmente nublado'],
    'Cloudy': ['Nublado', 'Nuageux', 'Bewölkt', 'Nublado'],
    'Overcast': ['Cubierto', 'Couvert', 'Bedeckt', 'Encoberto'],
    'Rain': ['Lluvia', 'Pluie', 'Regen', 'Chuva'],
    'Thunderstorms': ['Tormentas', 'Orages', 'Gewitter', 'Trovoada'],
    'Haze': ['Calima', 'Brume', 'Dunst', 'Neblina'],
    'Fog': ['Niebla', 'Brouillard', 'Nebel', 'Nevoeiro'],
    'Snow': ['Nieve', 'Neige', 'Schnee', 'Neve'],
    'Blizzard': ['Ventisca', 'Blizzard', 'Schneesturm', 'Nevasca'],
    'Spooky': ['Terrorífico', 'Effrayant', 'Gruselig', 'Assustador'],
};

const LANG_INDEX = { es: 0, fr: 1, de: 2, pt: 3 };

// user-generated content is never translated
const NO_I18N = '.bubble, .cp-text, .cv-prev, .n-text, .mv-body, .mv-subject, .note-text, .cp-head, .thread-head, .dl-error, [data-no-i18n], input, textarea';

const I18N = {
    lang: 'en',
    map: null,
    observer: null,

    t(s) {
        const v = this.map ? (this.map.get(s) || s) : s;
        return typeof Brand !== 'undefined' ? Brand.rw(v) : v;
    },

    /** re-run the text pass (new language or new branding) */
    refresh() { this.translateTree($('#screen')); const lt = $('#laptop'); if (lt) this.translateTree(lt); this.watch(); },

    weather(label) {
        const tr = WEATHER_T[label];
        return tr && LANG_INDEX[this.lang] !== undefined ? tr[LANG_INDEX[this.lang]] : label;
    },

    set(lang) {
        lang = LANG_INDEX[lang] !== undefined ? lang : 'en';
        if (lang === this.lang && (this.map || lang === 'en')) return;
        this.lang = lang;
        if (lang === 'en') {
            this.map = null;
        } else {
            const i = LANG_INDEX[lang];
            this.map = new Map(Object.entries(T).map(([en, tr]) => [en, tr[i]]));
        }
        document.documentElement.lang = lang;
        this.translateTree($('#screen'));
        this.watch();
    },

    translateText(node) {
        const orig = node.__en ?? node.nodeValue;
        const trimmed = orig.trim();
        if (!trimmed) return;
        const tr = this.map && trimmed.length <= 60 ? this.map.get(trimmed) : null;
        let next = tr ? orig.replace(trimmed, tr) : orig;
        if (typeof Brand !== 'undefined' && Brand.active) next = Brand.rw(next);   // this server's names
        if (next !== orig) {
            if (node.__en === undefined) node.__en = orig;
            if (node.nodeValue !== next) node.nodeValue = next;
        } else if (node.__en !== undefined && node.nodeValue !== node.__en) {
            node.nodeValue = node.__en; // back to English / the built-in names
        }
    },

    translateAttrs(elm) {
        for (const attr of ['placeholder', 'title', 'aria-label']) {
            if (!elm.hasAttribute || !elm.hasAttribute(attr)) continue;
            const key = '__en_' + attr;
            const orig = elm[key] ?? elm.getAttribute(attr);
            let next = (this.map ? this.map.get(orig.trim()) : null) || orig;
            if (typeof Brand !== 'undefined' && Brand.active) next = Brand.rw(next);
            if (next !== orig) { elm[key] = orig; elm.setAttribute(attr, next); }
            else if (elm[key] !== undefined) elm.setAttribute(attr, elm[key]);
        }
    },

    translateTree(root) {
        if (!root) return;
        if (root.nodeType === 3) {
            if (!root.parentElement || !root.parentElement.closest(NO_I18N)) this.translateText(root);
            return;
        }
        if (root.nodeType !== 1 || root.closest(NO_I18N)) return;
        this.translateAttrs(root);
        $$('[placeholder], [title], [aria-label]', root).forEach((e) => this.translateAttrs(e));
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => (n.parentElement && n.parentElement.closest(NO_I18N) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
        });
        let n;
        while ((n = walker.nextNode())) this.translateText(n);
    },

    watch() {
        if (this.observer) { this.observer.disconnect(); this.observer = null; }
        if (!this.map && !(typeof Brand !== 'undefined' && Brand.active)) return; // English + default branding: zero cost
        this.observer = new MutationObserver((muts) => {
            for (const m of muts) {
                if (m.type === 'characterData') this.translateTree(m.target);
                else m.addedNodes.forEach((n) => this.translateTree(n));
            }
        });
        this.observer.observe($('#screen'), { childList: true, subtree: true, characterData: true });
        const lt = $('#laptop');       // the laptop desktop (js/laptop.js) is translated the same way
        if (lt) { this.observer.observe(lt, { childList: true, subtree: true, characterData: true }); this.translateTree(lt); }
    },
};


