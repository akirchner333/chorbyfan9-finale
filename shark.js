const table = document.getElementById("list");

data.forEach(line => {
	let row = document.createElement("tr");
	row.innerHTML = `
		<td class='name'>${line[0]}</td>
		<td class='rating'>${line[1]}</td>
		<td class='comment'>${line[2]}</td>`
	table.appendChild(row);
});

document.onclick = function(){
	document.getElementById("scroll").className = "animate";
}