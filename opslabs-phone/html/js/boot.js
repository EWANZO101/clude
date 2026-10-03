'use strict';

document.addEventListener('DOMContentLoaded', () => {
    bootPhone();
    $('#app-layer').addEventListener('click', (e) => {
        // links inside apps never navigate the NUI frame
        const a = e.target.closest('a[href]');
        if (a) e.preventDefault();
    });
});
