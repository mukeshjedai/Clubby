const channels = [
  { id: "general", name: "General", isPrivate: false },
  { id: "ops", name: "Operations", isPrivate: true }
];

const messages = [];
const locations = new Map();

function newId() {
  return `${Date.now()}-${Math.floor(Math.random() * 1000000)}`;
}

module.exports = {
  channels,
  messages,
  locations,
  newId
};
