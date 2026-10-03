(function () {
  const form = document.getElementById("schedule-form");
  if (!form) return;

  const previewUrl = form.dataset.previewUrl;
  const currencySymbol = form.dataset.currencySymbol;
  const contractTotal = parseFloat(form.dataset.contractTotal);
  const allowOutstanding = form.dataset.allowOutstanding === "true";
  const maxPaymentMonths = form.dataset.maxPaymentMonths ? parseInt(form.dataset.maxPaymentMonths, 10) : null;

  function addMonthsJS(isoDate, months) {
    const d = new Date(isoDate + "T00:00:00");
    const day = d.getDate();
    d.setMonth(d.getMonth() + months);
    if (d.getDate() !== day) d.setDate(0); // clamp to last day of target month on overflow
    return d;
  }

  const frequencySel = form.querySelector('[name="frequency"]');
  const amountModeSel = form.querySelector('[name="amount_mode"]');
  const monthlyFields = form.querySelector("#monthly-fields");
  const customDateFields = form.querySelector("#custom-date-fields");
  const numInstalmentsField = form.querySelector("#num-instalments-field");
  const fixedAmountField = form.querySelector("#fixed-amount-field");
  const percentageField = form.querySelector("#percentage-field");
  const customAmountsField = form.querySelector("#custom-amounts-field");

  function updateFrequencyFields() {
    const freq = frequencySel.value;
    customDateFields.classList.toggle("hidden", freq !== "custom");
    numInstalmentsField.classList.toggle("hidden", freq === "custom" || freq === "one_time");
    monthlyFields.classList.toggle("hidden", !["monthly", "bimonthly"].includes(freq));
  }

  function updateAmountFields() {
    const mode = amountModeSel.value;
    fixedAmountField.classList.toggle("hidden", mode !== "fixed");
    percentageField.classList.toggle("hidden", mode !== "percentage");
    customAmountsField.classList.toggle("hidden", mode !== "custom");
  }

  frequencySel.addEventListener("change", updateFrequencyFields);
  amountModeSel.addEventListener("change", updateAmountFields);
  updateFrequencyFields();
  updateAmountFields();

  const previewSection = document.getElementById("preview-section");
  const previewBody = document.getElementById("preview-body");
  const confirmBtn = document.getElementById("confirm-btn");
  const sumScheduled = document.getElementById("sum-scheduled");
  const sumRemaining = document.getElementById("sum-remaining");
  const sumFirst = document.getElementById("sum-first");
  const sumFinal = document.getElementById("sum-final");
  const balanceWarning = document.getElementById("balance-warning");
  const monthsWarning = document.getElementById("months-warning");

  function fmt(n) {
    return currencySymbol + Number(n).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }

  function recalcTotals() {
    let total = 0;
    let maxRowDate = null;
    previewBody.querySelectorAll("tr").forEach((row) => {
      const amt = parseFloat(row.querySelector(".row-amount").value) || 0;
      total += amt;
      const dateVal = row.querySelector(".row-date").value;
      if (dateVal && (!maxRowDate || dateVal > maxRowDate)) maxRowDate = dateVal;
    });
    total = Math.round(total * 100) / 100;
    const remaining = Math.round((contractTotal - total) * 100) / 100;
    sumScheduled.textContent = fmt(total);
    sumRemaining.textContent = fmt(remaining);

    let balanceOk = true;
    if (Math.abs(remaining) > 0.009 && !allowOutstanding) {
      balanceWarning.classList.remove("hidden");
      balanceWarning.textContent = remaining > 0
        ? `Schedule is ${fmt(remaining)} short of the contract total.`
        : `Schedule exceeds the contract total by ${fmt(Math.abs(remaining))}.`;
      balanceOk = false;
    } else {
      balanceWarning.classList.add("hidden");
    }

    let monthsOk = true;
    if (monthsWarning && maxPaymentMonths && maxRowDate) {
      const startDateVal = form.querySelector('[name="start_date"]').value;
      if (startDateVal) {
        const cutoff = addMonthsJS(startDateVal, maxPaymentMonths);
        const finalDate = new Date(maxRowDate + "T00:00:00");
        if (finalDate > cutoff) {
          const cutoffStr = cutoff.toISOString().slice(0, 10);
          monthsWarning.classList.remove("hidden");
          monthsWarning.textContent = `The full balance must be paid within ${maxPaymentMonths} months of the first payment — by ${cutoffStr}. The final instalment above falls after that.`;
          monthsOk = false;
        } else {
          monthsWarning.classList.add("hidden");
        }
      }
    }

    if (balanceOk && monthsOk) {
      confirmBtn.disabled = false;
      confirmBtn.classList.remove("opacity-40", "cursor-not-allowed");
    } else {
      confirmBtn.disabled = true;
      confirmBtn.classList.add("opacity-40", "cursor-not-allowed");
    }
  }

  function renderPreview(data) {
    previewBody.innerHTML = "";
    data.rows.forEach((row, i) => {
      const tr = document.createElement("tr");
      tr.className = "border-t border-ink-line";
      tr.innerHTML = `
        <td class="py-2 pr-3 text-muted num">${row.sequence}</td>
        <td class="py-2 pr-3"><input type="date" class="row-date bg-ink-raised border border-ink-line rounded px-2 py-1 text-sm num" value="${row.date}"></td>
        <td class="py-2 pr-3"><input type="text" class="row-label bg-ink-raised border border-ink-line rounded px-2 py-1 text-sm w-32" value="${row.label || ''}" placeholder="Instalment"></td>
        <td class="py-2 pr-3 text-right"><input type="number" step="0.01" class="row-amount bg-ink-raised border border-ink-line rounded px-2 py-1 text-sm num text-right w-28" value="${row.amount}"></td>
        <td class="py-2"><span class="stamp text-gold">Upcoming</span></td>
      `;
      previewBody.appendChild(tr);
    });
    previewBody.querySelectorAll(".row-amount").forEach((el) => el.addEventListener("input", recalcTotals));

    sumFirst.textContent = data.first_payment_date || "—";
    sumFinal.textContent = data.final_payment_date || "—";
    previewSection.classList.remove("hidden");
    recalcTotals();
    previewSection.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  document.getElementById("preview-btn").addEventListener("click", async () => {
    const fd = new FormData(form);
    const res = await fetch(previewUrl, { method: "POST", body: fd });
    const data = await res.json();
    if (data.error) {
      alert(data.error);
      return;
    }
    renderPreview(data);
  });

  form.addEventListener("submit", (e) => {
    if (previewSection.classList.contains("hidden")) {
      e.preventDefault();
      alert("Generate a preview first.");
      return;
    }
    const rows = [];
    previewBody.querySelectorAll("tr").forEach((row, i) => {
      rows.push({
        sequence: i + 1,
        date: row.querySelector(".row-date").value,
        amount: parseFloat(row.querySelector(".row-amount").value) || 0,
        label: row.querySelector(".row-label").value || null,
      });
    });
    const meta = {
      frequency: frequencySel.value,
      start_date: form.querySelector('[name="start_date"]').value,
      day_of_month: form.querySelector('[name="day_of_month"]').value || null,
      amount_mode: amountModeSel.value,
      auto_end: form.querySelector('[name="auto_end"]').checked,
    };
    form.querySelector('[name="rows_json"]').value = JSON.stringify(rows);
    form.querySelector('[name="meta_json"]').value = JSON.stringify(meta);
  });
})();
